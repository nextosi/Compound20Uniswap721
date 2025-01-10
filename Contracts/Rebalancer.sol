// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { OracleManager as OracleMgr } from "./OracleManager.sol";

/**
 * @dev Minimal interface for a Vault that the Rebalancer interacts with.
 */
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
 *
 *         The code here is split into smaller internal helpers to avoid 
 *         'Stack Too Deep' errors in Solidity 0.8.x.
 */
contract Rebalancer is Ownable {
    OracleMgr public oracleManager;

    uint256 public minPriceAllowed;
    uint256 public maxPriceAllowed;

    bool public defaultAutoCompound;

    event RebalancePerformed(
        address indexed vault,
        uint256 tokenId,
        uint256 amount0Removed,
        uint256 amount1Removed,
        uint256 amount0Added,
        uint256 amount1Added,
        bool autoCompounded,
        uint256 mintedShares
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

        oracleManager     = OracleMgr(_oracleManager);
        minPriceAllowed   = _minPrice;
        maxPriceAllowed   = _maxPrice;

        emit PriceBoundsUpdated(_minPrice, _maxPrice);
    }

    // ------------------ Owner Setters ------------------
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

    // ------------------ Data Structures ------------------
    /**
     * @dev The arguments we decode from `rebalance(...) data`.
     */
    struct ExtendedRebalanceArgs {
        uint128 liquidityToRemove;
        uint256 amount0MinRemove;
        uint256 amount1MinRemove;
        uint256 amount0DesiredAdd;
        uint256 amount1DesiredAdd;
        uint256 deadline;
        bool autoCompound;              
        uint256 extraValueForCompounding;
    }

   
    struct RebalanceLocalVars {
        address posMgr;
        uint256 tokenId;
        uint128 currentLiquidity;
        uint256 amt0Removed;
        uint256 amt1Removed;
        uint256 collect0;
        uint256 collect1;
        uint128 newLiquidity;
        uint256 amt0Added;
        uint256 amt1Added;
        bool doAuto;
        uint256 minted;
    }

    // ------------------ External Entry ------------------
    /**
     * @notice Rebalances the position by removing liquidity, collecting tokens, optionally adding more,
     *         and optionally auto-compounding (minting shares).
     *
     * @param vault The address of the vault implementing IMultiNftVaultRebalance
     * @param data  The ABI-encoded ExtendedRebalanceArgs
     */
    function rebalance(address vault, bytes calldata data) external onlyOwner {
        require(vault != address(0), "Rebalancer: invalid vault");

        RebalanceLocalVars memory v = _rebalanceInternal(vault, data);


        emit RebalancePerformed(
            vault,
            v.tokenId,
            v.amt0Removed,
            v.amt1Removed,
            v.amt0Added,
            v.amt1Added,
            v.doAuto,
            v.minted
        );
    }

    // ------------------ Internal Rebalance Logic ------------------
    /**
     * @dev Splits the rebalance logic into a separate internal function that returns
     *      a struct. 
     */
    function _rebalanceInternal(address vault, bytes calldata data)
        private
        returns (RebalanceLocalVars memory v)
    {
        // 1) decode arguments
        ExtendedRebalanceArgs memory args = _decodeArgs(data);

        // 2) get the vault interface
        IMultiNftVaultRebalance vaultInterface = IMultiNftVaultRebalance(vault);
        v.tokenId = vaultInterface.vaultPositionTokenId();
        v.posMgr  = vaultInterface.positionManager();

        // 3) optional price checks
        _checkPriceConstraints(vaultInterface);

        // 4) fetch current liquidity
        v.currentLiquidity = _fetchLiquidity(v.posMgr, v.tokenId);
        require(v.currentLiquidity >= args.liquidityToRemove, "Not enough liquidity");

        // 5) remove liquidity
        (v.amt0Removed, v.amt1Removed) = _removeLiquidity(
            v.posMgr,
            v.tokenId,
            args.liquidityToRemove,
            args.amount0MinRemove,
            args.amount1MinRemove,
            args.deadline
        );

        // 6) collect tokens
        (v.collect0, v.collect1) = _collectAll(v.posMgr, vault, v.tokenId);

        // 7) optionally add more liquidity
        if (args.amount0DesiredAdd > 0 || args.amount1DesiredAdd > 0) {
            (v.newLiquidity, v.amt0Added, v.amt1Added) = _addLiquidity(
                v.posMgr,
                v.tokenId,
                args.amount0DesiredAdd,
                args.amount1DesiredAdd,
                args.deadline
            );
        }

        // 8) auto-compound?
        v.doAuto = (args.autoCompound || defaultAutoCompound);
        if (v.doAuto && args.extraValueForCompounding > 0) {
            vaultInterface.rebalancerMintShares(args.extraValueForCompounding, owner());
            v.minted = args.extraValueForCompounding; 
        }

        return v;
    }

    // ------------------ Internal Helpers ------------------
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

    function _fetchLiquidity(address posMgr, uint256 tokenId)
        private
        view
        returns (uint128 liquidity)
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
            ,
            ,
            liquidity, // we only read out 'liquidity' from the tuple
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
        uint128 liquidityToRemove,
        uint256 amount0MinRemove,
        uint256 amount1MinRemove,
        uint256 deadline
    )
        private
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidityToRemove == 0) {
            return (0, 0);
        }
        INonfungiblePositionManager.DecreaseLiquidityParams memory p =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0MinRemove,
                amount1Min: amount1MinRemove,
                deadline: deadline
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
        uint256 amount0DesiredAdd,
        uint256 amount1DesiredAdd,
        uint256 deadline
    )
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0DesiredAdd,
                amount1Desired: amount1DesiredAdd,
                amount0Min: 0,  // could pass from arguments if needed
                amount1Min: 0,  // could pass from arguments if needed
                deadline: deadline
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
