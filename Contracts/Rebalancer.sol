// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { OracleManager as OracleMgr } from "./OracleManager.sol";

/**
 * @dev Minimal interface for a Vault that the Rebalancer interacts with.
 */
interface IVaultRebalance {
    function vaultPositionTokenId() external view returns (uint256);
    function positionManager() external view returns (address);
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals);
}

/**
 * @title Rebalancer
 * @notice Rebalances a Uniswap V3 position for a Vault by removing/adding liquidity,
 *         optionally checking an OracleManager for price constraints.
 */
contract Rebalancer is Ownable {
    /// OracleManager reference
    OracleMgr public oracleManager;

    /// Price constraints
    uint256 public minPriceAllowed;
    uint256 public maxPriceAllowed;

    event RebalancePerformed(
        address indexed vault,
        uint256 tokenId,
        uint256 amount0Removed,
        uint256 amount1Removed,
        uint256 amount0Added,
        uint256 amount1Added
    );

    event PriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);

    /**
     * @dev If your Ownable requires an `initialOwner`: do `Ownable(initialOwner)` below.
     */
    constructor(
        address initialOwner,
        address _oracleManager,
        uint256 _minPrice,
        uint256 _maxPrice
    )
        // If your Ownable is a version that needs an address in the constructor:
        Ownable(initialOwner)
        // Otherwise, remove the above line
    {
        require(_oracleManager != address(0), "Rebalancer: invalid oracle");
        require(_minPrice <= _maxPrice, "Rebalancer: minPrice>maxPrice");

        oracleManager = OracleMgr(_oracleManager);
        minPriceAllowed = _minPrice;
        maxPriceAllowed = _maxPrice;

        emit PriceBoundsUpdated(_minPrice, _maxPrice);
    }

    function setPriceBounds(uint256 newMin, uint256 newMax) external onlyOwner {
        require(newMin <= newMax, "Rebalancer: minPrice>maxPrice");
        minPriceAllowed = newMin;
        maxPriceAllowed = newMax;
        emit PriceBoundsUpdated(newMin, newMax);
    }

    function setOracleManager(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Rebalancer: invalid oracle");
        oracleManager = OracleMgr(newOracle);
    }

    /**
     * @dev The arguments decoded from `rebalance(...) data`.
     */
    struct RebalanceArgs {
        uint128 liquidityToRemove;
        uint256 amount0MinRemove;
        uint256 amount1MinRemove;
        uint256 amount0DesiredAdd;
        uint256 amount1DesiredAdd;
        uint256 deadline;
    }

    /**
     * @notice Rebalances the position by removing liquidity, collecting tokens, optionally adding more.
     *
     * @param vault The address of the vault implementing IVaultRebalance
     * @param data  The ABI-encoded RebalanceArgs
     */
    function rebalance(address vault, bytes calldata data) external onlyOwner {
        require(vault != address(0), "Rebalancer: invalid vault");

        // decode
        RebalanceArgs memory args = _decodeRebalanceArgs(data);

        // step 1: check vault + position manager references
        IVaultRebalance vaultInterface = IVaultRebalance(vault);
        address posMgr;
        uint256 tokenId;
        {
            // scoping block
            tokenId = vaultInterface.vaultPositionTokenId();
            posMgr = vaultInterface.positionManager();
            require(posMgr != address(0), "Rebalancer: invalid position manager");
        }

        // step 2: optional price checks
        _checkPriceConstraints(vaultInterface);

        // step 3: get current liquidity
        uint128 currentLiquidity = _fetchLiquidity(posMgr, tokenId);
        require(currentLiquidity >= args.liquidityToRemove, "Rebalancer: not enough liquidity");

        // step 4: remove liquidity
        (uint256 amt0Removed, uint256 amt1Removed) = _removeLiquidity(
            posMgr,
            tokenId,
            args
        );

        // step 5: collect tokens
        (uint256 collect0, uint256 collect1) = _collectAll(
            posMgr,
            vault,
            tokenId
        );

        // step 6: optionally add more liquidity
        uint128 newLiquidity;
        uint256 amt0Added;
        uint256 amt1Added;

        if (args.amount0DesiredAdd > 0 || args.amount1DesiredAdd > 0) {
            (newLiquidity, amt0Added, amt1Added) = _addLiquidity(posMgr, tokenId, args);
        }

        emit RebalancePerformed(
            vault,
            tokenId,
            amt0Removed,
            amt1Removed,
            amt0Added,
            amt1Added
        );
    }

    // ---------------------------------------------------------------------
    // INTERNAL / PRIVATE HELPERS
    // ---------------------------------------------------------------------

    function _decodeRebalanceArgs(bytes calldata data) private pure returns (RebalanceArgs memory r) {
        (
            r.liquidityToRemove,
            r.amount0MinRemove,
            r.amount1MinRemove,
            r.amount0DesiredAdd,
            r.amount1DesiredAdd,
            r.deadline
        ) = abi.decode(data, (uint128, uint256, uint256, uint256, uint256, uint256));
    }

    function _checkPriceConstraints(IVaultRebalance vaultInterface) private view {
        if (minPriceAllowed > 0 || maxPriceAllowed > 0) {
            (uint256 vaultPrice, ) = vaultInterface.getUnderlyingPrice();
            require(
                vaultPrice >= minPriceAllowed && vaultPrice <= maxPriceAllowed,
                "Rebalancer: vault price out of allowed range"
            );
        }
    }

    function _fetchLiquidity(address posMgr, uint256 tokenId) private view returns (uint128 liquidity) {
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
            ,
            ,
            liquidity,
            ,
            ,
            ,
        ) = abi.decode(
            result,
            (
                uint96,
                address,
                address,
                address,
                uint24,
                int24,
                int24,
                uint128,
                uint256,
                uint256,
                uint128,
                uint128
            )
        );
    }

    /**
     * @dev Removes liquidity using args.
     */
    function _removeLiquidity(
        address posMgr,
        uint256 tokenId,
        RebalanceArgs memory args
    )
        private
        returns (uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.DecreaseLiquidityParams memory p =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: args.liquidityToRemove,
                amount0Min: args.amount0MinRemove,
                amount1Min: args.amount1MinRemove,
                deadline: args.deadline
            });

        (amount0, amount1) = INonfungiblePositionManager(posMgr).decreaseLiquidity(p);
    }

    function _collectAll(address posMgr, address recipient, uint256 tokenId)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.CollectParams memory cp =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = INonfungiblePositionManager(posMgr).collect(cp);
    }

    function _addLiquidity(
        address posMgr,
        uint256 tokenId,
        RebalanceArgs memory args
    )
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        // Adjust or store if you want to pass min amounts for adding liquidity
        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: args.amount0DesiredAdd,
                amount1Desired: args.amount1DesiredAdd,
                amount0Min: 0,
                amount1Min: 0,
                deadline: args.deadline
            });

        (liquidity, used0, used1) = INonfungiblePositionManager(posMgr).increaseLiquidity(p);
    }

    /**
     * @dev Helper to decode revert messages from position manager calls
     */
    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "Rebalancer: call reverted w/o message";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
