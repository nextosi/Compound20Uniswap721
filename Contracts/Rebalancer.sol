// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { OracleManager as OracleMgr } from "./OracleManager.sol";

interface IMultiNftVaultRebalance {

    function vaultPositionTokenId() external view returns (uint256); 
    

    function positionManager() external view returns (address);

    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals);

 
    function rebalancerMintShares(uint256 extraValue, address to) external;

}

/**
 * @title Rebalancer
 * @notice Rebalances a Uniswap V3 position for a Vault by removing/adding liquidity,
 *         optionally checking an OracleManager for price constraints, 
 *         and providing an “auto-compounding” feature that can mint shares.
 */
contract Rebalancer is Ownable {
    OracleMgr public oracleManager;

    uint256 public minPriceAllowed;
    uint256 public maxPriceAllowed;

    // If we want a default autoCompound setting or a ratio:
    bool public defaultAutoCompound; 
    // Or you might store a ratio, e.g. 100% of fees are auto-added, etc.

    event RebalancePerformed(
        address indexed vault,
        uint256 tokenId,
        uint256 amount0Removed,
        uint256 amount1Removed,
        uint256 amount0Added,
        uint256 amount1Added,
        bool autoCompounded,
        uint256 mintedShares // if any
    );

    event PriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);

    constructor(
        address initialOwner,
        address _oracleManager,
        uint256 _minPrice,
        uint256 _maxPrice
    ) Ownable(initialOwner)
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

    function setDefaultAutoCompound(bool autoCompound) external onlyOwner {
        defaultAutoCompound = autoCompound;
    }

    /**
     * @dev The arguments decoded from `rebalance(...) data`.
     *      We add `autoCompound` plus an optional `extraValueForCompounding`.
     */
    struct ExtendedRebalanceArgs {
        uint128 liquidityToRemove;
        uint256 amount0MinRemove;
        uint256 amount1MinRemove;
        uint256 amount0DesiredAdd;
        uint256 amount1DesiredAdd;
        uint256 deadline;
        bool autoCompound;              // if true, we auto-collect fees and optionally call vault to mint shares
        uint256 extraValueForCompounding; // if we want to deposit new tokens or handle a certain extra amount
    }

    /**
     * @notice Rebalances the position by removing liquidity, collecting tokens, optionally adding more.
     *         Also can auto-claim any fees and call `rebalancerMintShares(...)` on the vault to produce new shares.
     *
     * @param vault The address of the vault implementing IMultiNftVaultRebalance
     * @param data  The ABI-encoded ExtendedRebalanceArgs
     */
    function rebalance(address vault, bytes calldata data) external onlyOwner {
        require(vault != address(0), "Rebalancer: invalid vault");

        // decode
        ExtendedRebalanceArgs memory args = _decodeArgs(data);

        IMultiNftVaultRebalance vaultInterface = IMultiNftVaultRebalance(vault);

        uint256 tokenId = vaultInterface.vaultPositionTokenId(); 

        // step 1: optional price checks
        _checkPriceConstraints(vaultInterface);

        // step 2: fetch current liquidity from the NFPM
        address posMgr = vaultInterface.positionManager();
        require(posMgr != address(0), "Rebalancer: invalid posMgr");
        uint128 currentLiquidity = _fetchLiquidity(posMgr, tokenId);
        require(currentLiquidity >= args.liquidityToRemove, "Not enough liquidity");

        // step 3: remove liquidity
        (uint256 amt0Removed, uint256 amt1Removed) = _removeLiquidity(
            posMgr,
            tokenId,
            args
        );

        // step 4: collect tokens (fees + the portion from remove) 
        //         so that the vault has them available
        (uint256 collect0, uint256 collect1) = _collectAll(posMgr, vault, tokenId);

        // step 5: optionally add more liquidity
        uint128 newLiquidity;
        uint256 amt0Added;
        uint256 amt1Added;

        if (args.amount0DesiredAdd > 0 || args.amount1DesiredAdd > 0) {
            (newLiquidity, amt0Added, amt1Added) = _addLiquidity(posMgr, tokenId, args);
        }

        // step 6: auto-compound?
        bool doAuto = args.autoCompound || defaultAutoCompound;
        uint256 minted = 0;
        if (doAuto) {
            // If your vault supports a method for the rebalancer to call 
            // e.g. `rebalancerMintShares(...)` to handle any extra tokens or 
            // deposit them as an auto-compound. 
            // This logic is up to you. Example:
            if (args.extraValueForCompounding > 0) {
                // calls the vault’s method to mint new shares
                // The vault must have an exposed function like:
                //   function rebalancerMintShares(uint256 extraValue, address to) external;
                //   require(msg.sender == address(rebalancer));
                vaultInterface.rebalancerMintShares(args.extraValueForCompounding, owner());
                minted = args.extraValueForCompounding; // or the actual minted share count
            }
            // If you want the rebalancer to also add the newly collected fees into the vault’s 
            
        }

        emit RebalancePerformed(
            vault,
            tokenId,
            amt0Removed,
            amt1Removed,
            amt0Added,
            amt1Added,
            doAuto,
            minted
        );
    }

    // ---------------------------------------------------------------------
    // INTERNAL / PRIVATE HELPERS
    // ---------------------------------------------------------------------
    function _decodeArgs(bytes calldata data) private pure returns (ExtendedRebalanceArgs memory a) {
        (
            a.liquidityToRemove,
            a.amount0MinRemove,
            a.amount1MinRemove,
            a.amount0DesiredAdd,
            a.amount1DesiredAdd,
            a.deadline,
            a.autoCompound,
            a.extraValueForCompounding
        ) = abi.decode(data, (uint128, uint256, uint256, uint256, uint256, uint256, bool, uint256));
    }

    function _checkPriceConstraints(IMultiNftVaultRebalance vaultInterface) private view {
        if (minPriceAllowed > 0 || maxPriceAllowed > 0) {
            (uint256 vaultPrice, ) = vaultInterface.getUnderlyingPrice();
            require(
                vaultPrice >= minPriceAllowed && vaultPrice <= maxPriceAllowed,
                "Rebalancer: vault price out of range"
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

    function _removeLiquidity(
        address posMgr,
        uint256 tokenId,
        ExtendedRebalanceArgs memory args
    )
        private
        returns (uint256 amount0, uint256 amount1)
    {
        if (args.liquidityToRemove == 0) {
            return (0, 0);
        }
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
        ExtendedRebalanceArgs memory args
    )
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: args.amount0DesiredAdd,
                amount1Desired: args.amount1DesiredAdd,
                amount0Min: 0, // or pass from args
                amount1Min: 0, // or pass from args
                deadline: args.deadline
            });

        (liquidity, used0, used1) = INonfungiblePositionManager(posMgr).increaseLiquidity(p);
    }

    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "Rebalancer: call reverted w/o message";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
