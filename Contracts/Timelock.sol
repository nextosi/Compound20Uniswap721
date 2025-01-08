// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

import "./OracleManager.sol";

/**
 * @dev Minimal interface for a Vault that the Rebalancer interacts with.
 *      Rebalancer calls:
 *        1. vaultPositionTokenId() to get the Uniswap V3 position ID
 *        2. positionManager() to get the NonfungiblePositionManager address
 *        3. getUnderlyingPrice() if we need to check the vault’s current price (poolPrice)
 *        4. owner() if gatingActive is set, only that owner/timelock can call the rebalance
 */
interface IVaultRebalance {
    function vaultPositionTokenId() external view returns (uint256);
    function positionManager() external view returns (address);
    function owner() external view returns (address);
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals);
}

/**
 * @title Rebalancer
 * @notice A contract that can perform rebalancing on a Uniswap V3 position owned by a vault:
 *         1) Optionally enforce gating by requiring that only an authorized address (vault owner/timelock) can call
 *         2) Optionally enforce price constraints (minPriceAllowed, maxPriceAllowed) by comparing 
 *            the vault’s reported pool price to the allowed range
 *         3) Remove liquidity from old range (decreaseLiquidity)
 *         4) Collect tokens
 *         5) Optionally add liquidity into a new range (increaseLiquidity)
 *
 *         This contract references an OracleManager only if needed for advanced aggregator checks. 
 *         Currently, we demonstrate a direct getUnderlyingPrice() call on the vault if enforcePriceConstraints is set.
 *
 *         The data parameter for rebalance is flexible, letting the caller pass newTickLower, newTickUpper, etc.
 */
contract Rebalancer is Ownable {
    /**
     * @dev Reference to an OracleManager if you want aggregator checks 
     *      or more advanced usage. Not strictly required if the vault 
     *      itself provides getUnderlyingPrice().
     */
    OracleManager public oracleManager;

    /**
     * @dev For each vault, store whether gating and price constraints 
     *      are enforced, along with minPriceAllowed and maxPriceAllowed. 
     *      The vault’s authorizedCaller is typically the vault owner or a timelock.
     */
    struct VaultOptions {
        bool gatingActive;
        address authorizedCaller;    // e.g. vault owner, timelock, or DAO
        bool enforcePriceConstraints;
        uint256 minPriceAllowed;    // in 1e8 or aggregator decimals
        uint256 maxPriceAllowed;    // in 1e8 or aggregator decimals
    }

    /**
     * @dev vault -> VaultOptions
     */
    mapping(address => VaultOptions) public vaultOptions;

    /**
     * @dev Emitted after a successful rebalance operation.
     */
    event RebalancePerformed(
        address indexed vault,
        uint256 tokenId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Removed,
        uint256 amount1Removed,
        uint256 amount0Added,
        uint256 amount1Added
    );

    /**
     * @dev Emitted whenever we update the OracleManager reference.
     */
    event OracleManagerUpdated(address newOracle);

    /**
     * @dev Emitted whenever we update a vault’s configuration (gating, price constraints, etc).
     */
    event VaultOptionsUpdated(
        address indexed vault,
        bool gatingActive,
        address authorizedCaller,
        bool enforcePriceConstraints,
        uint256 minPriceAllowed,
        uint256 maxPriceAllowed
    );

    /**
     * @param _oracleManager The OracleManager, if needed for aggregator checks or future expansions
     */
    constructor(address _oracleManager) {
        oracleManager = OracleManager(_oracleManager);
        emit OracleManagerUpdated(_oracleManager);
    }

    /**
     * @notice Updates the reference to OracleManager if needed (onlyOwner).
     * @param newOracle The new OracleManager address
     */
    function setOracleManager(address newOracle) external onlyOwner {
        oracleManager = OracleManager(newOracle);
        emit OracleManagerUpdated(newOracle);
    }

    /**
     * @notice Updates gating and price constraints for a specific vault (onlyOwner).
     *         gatingActive => if true, only authorizedCaller can call rebalance for that vault
     *         enforcePriceConstraints => if true, we check the vault’s getUnderlyingPrice 
     *                                   against minPriceAllowed, maxPriceAllowed
     */
    function setVaultOptions(
        address vault,
        bool gatingActive,
        address authorizedCaller,
        bool enforcePriceConstraints,
        uint256 minPriceAllowed,
        uint256 maxPriceAllowed
    ) external onlyOwner {
        VaultOptions storage opts = vaultOptions[vault];
        opts.gatingActive = gatingActive;
        opts.authorizedCaller = authorizedCaller;
        opts.enforcePriceConstraints = enforcePriceConstraints;
        opts.minPriceAllowed = minPriceAllowed;
        opts.maxPriceAllowed = maxPriceAllowed;

        emit VaultOptionsUpdated(
            vault,
            gatingActive,
            authorizedCaller,
            enforcePriceConstraints,
            minPriceAllowed,
            maxPriceAllowed
        );
    }

    /**
     * @notice Performs a rebalance on a vault’s Uniswap V3 position. 
     *         Steps:
     *         1) If gatingActive, require msg.sender == authorizedCaller
     *         2) If enforcePriceConstraints, compare vault’s getUnderlyingPrice() to allowed range
     *         3) Remove some or all liquidity from old range
     *         4) Collect tokens to the vault
     *         5) Optionally add liquidity to new range
     *
     * @param vault The vault implementing IVaultRebalance
     * @param data  Encoded parameters:
     *             (
     *               int24 newTickLower,
     *               int24 newTickUpper,
     *               uint128 liquidityToRemove,
     *               uint256 amount0MinRemove,
     *               uint256 amount1MinRemove,
     *               uint256 amount0DesiredAdd,
     *               uint256 amount1DesiredAdd,
     *               uint256 amount0MinAdd,
     *               uint256 amount1MinAdd,
     *               uint256 deadline
     *             )
     */
    function rebalance(address vault, bytes calldata data) external {
        VaultOptions memory opts = vaultOptions[vault];

        if (opts.gatingActive) {
            require(
                msg.sender == opts.authorizedCaller,
                "Rebalancer: not authorized to rebalance this vault"
            );
        }

        if (opts.enforcePriceConstraints) {
            (uint256 poolPrice, ) = IVaultRebalance(vault).getUnderlyingPrice();
            require(
                poolPrice >= opts.minPriceAllowed && poolPrice <= opts.maxPriceAllowed,
                "Rebalancer: vault price out of allowed range"
            );
        }

        (
            int24 newTickLower,
            int24 newTickUpper,
            uint128 liquidityToRemove,
            uint256 amount0MinRemove,
            uint256 amount1MinRemove,
            uint256 amount0DesiredAdd,
            uint256 amount1DesiredAdd,
            uint256 amount0MinAdd,
            uint256 amount1MinAdd,
            uint256 deadline
        ) = abi.decode(
            data,
            (int24, int24, uint128, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
        );

        // Read vault’s position info
        IVaultRebalance vaultInterface = IVaultRebalance(vault);
        uint256 tokenId = vaultInterface.vaultPositionTokenId();
        address posMgr = vaultInterface.positionManager();
        require(posMgr != address(0), "Rebalancer: invalid positionMgr");

        // Retrieve old range and liquidity
        (int24 oldTickLower, int24 oldTickUpper, uint128 currentLiquidity) = _getOldRangeAndLiquidity(posMgr, tokenId);

        require(currentLiquidity >= liquidityToRemove, "Rebalancer: insufficient liquidity to remove");

        // Step A: remove liquidity
        (uint256 amount0Removed, uint256 amount1Removed) = _removeLiquidity(
            posMgr,
            tokenId,
            liquidityToRemove,
            amount0MinRemove,
            amount1MinRemove,
            deadline
        );

        // Step B: collect to vault
        (uint256 collect0, uint256 collect1) = _collectAll(posMgr, vault, tokenId);

        // Step C: add new liquidity if specified
        (uint128 newLiquidity, uint256 added0, uint256 added1) = (0, 0, 0);
        if (amount0DesiredAdd > 0 || amount1DesiredAdd > 0) {
            (newLiquidity, added0, added1) = _addLiquidity(
                posMgr,
                vault,
                tokenId,
                newTickLower,
                newTickUpper,
                amount0DesiredAdd,
                amount1DesiredAdd,
                amount0MinAdd,
                amount1MinAdd,
                deadline
            );
        }

        emit RebalancePerformed(
            vault,
            tokenId,
            oldTickLower,
            oldTickUpper,
            newTickLower,
            newTickUpper,
            amount0Removed,
            amount1Removed,
            added0,
            added1
        );
    }

    /**
     * @dev Internal: retrieve oldTickLower, oldTickUpper, and currentLiquidity from positions(tokenId).
     */
    function _getOldRangeAndLiquidity(address posMgr, uint256 tokenId)
        internal
        view
        returns (int24 oldTickLower, int24 oldTickUpper, uint128 currentLiquidity)
    {
        (bool success, bytes memory result) = posMgr.staticcall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId)
        );
        require(success, _getRevertMsg(result));

        (
            ,
            ,
            ,
            ,
            ,
            oldTickLower,
            oldTickUpper,
            currentLiquidity,
            ,
            ,
            ,
        ) = abi.decode(
            result,
            (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
        );
    }

    /**
     * @dev Internal: remove liquidity from the old range.
     */
    function _removeLiquidity(
        address posMgr,
        uint256 tokenId,
        uint128 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });

        (amount0, amount1) = INonfungiblePositionManager(posMgr).decreaseLiquidity(params);
    }

    /**
     * @dev Internal: collect all tokens/fees to the vault address.
     */
    function _collectAll(address posMgr, address vault, uint256 tokenId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = INonfungiblePositionManager(posMgr).collect(collectParams);
    }

    /**
     * @dev Internal: add liquidity to a new (or same) tick range. 
     */
    function _addLiquidity(
        address posMgr,
        address vault,
        uint256 tokenId,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal returns (uint128 liquidity, uint256 used0, uint256 used1) {
        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                deadline: deadline
            });

        (liquidity, used0, used1) = INonfungiblePositionManager(posMgr).increaseLiquidity(params);
    }

    /**
     * @dev Helper to decode revert reasons from staticcall or call.
     */
    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "Rebalancer: call reverted w/o msg";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
