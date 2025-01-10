// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title OracleManager
 * @notice Manages aggregator references (Chainlink) for normal tokens,
 *         plus specialized logic for Uniswap V3 vault tokens.
 */

/* ---------------------------------------------------------------------
 * 1) Chainlink aggregator interface for testnet
 * --------------------------------------------------------------------- */
import "https://github.com/smartcontractkit/chainlink/blob/v1.6.0/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/* ---------------------------------------------------------------------
 * 2) OpenZeppelin v4.8.3
 * --------------------------------------------------------------------- */
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.3/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.3/contracts/utils/Address.sol";

/* ---------------------------------------------------------------------
 * 3) Uniswap v3-periphery (0.8) for LiquidityAmounts
 * --------------------------------------------------------------------- */
import "https://github.com/Uniswap/v3-periphery/blob/0.8/contracts/libraries/LiquidityAmounts.sol";

/* ---------------------------------------------------------------------
 * Local TickMathLocal for 0.8.x
 * ---------------------------------------------------------------------
 */
library TickMathLocal {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        uint256 absTick = (tick < 0) 
            ? uint256(uint24(uint24(-tick))) 
            : uint256(uint24(uint24(tick)));

        uint256 ratio = 0x100000000000000000000000000000000; // 1 << 128

        if (absTick & 0x1     != 0) ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1f6a7a2e3fadacb4c9b) >> 128;
        if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }

        uint256 shifted = ratio >> 32;
        require(shifted <= type(uint160).max, "Price overflow");
        sqrtPriceX96 = uint160(shifted);
    }
}

/* ---------------------------------------------------------------------
 * Minimal Interfaces for Vault & NFPM & Pool
 * --------------------------------------------------------------------- */
interface IVaultToken {
    function totalSupply() external view returns (uint256);
    function vaultTokenId() external view returns (uint256);
    function positionManager() external view returns (address);
    function v3Pool() external view returns (address);
}

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/* ---------------------------------------------------------------------
 * OracleManager Implementation
 * --------------------------------------------------------------------- */
contract OracleManager is Ownable {
    struct OracleData {
        address primaryAggregator;
        address fallbackAggregator;
        bool useFallbackIfError;
        uint8 decimalsOverride;
        bool isVaultToken;
    }

    struct VaultUnderlyingFeeds {
        address token0Aggregator;
        address token1Aggregator;
        uint8 token0Decimals;
        uint8 token1Decimals;
        bool exists;
    }

    mapping(address => OracleData) public oracleConfigs;
    mapping(address => VaultUnderlyingFeeds) public vaultFeeds;

    event OracleConfigUpdated(
        address indexed token,
        address primaryAggregator,
        address fallbackAggregator,
        bool useFallbackIfError,
        uint8 decimalsOverride,
        bool isVaultToken
    );

    event VaultUnderlyingFeedsUpdated(
        address indexed vaultToken,
        address token0Aggregator,
        address token1Aggregator,
        uint8 token0Decimals,
        uint8 token1Decimals
    );

    constructor(address initialOwner) {
        require(initialOwner != address(0), "OracleManager: invalid owner");
        _transferOwnership(initialOwner);
    }

    function setOracleConfig(
        address token,
        address primaryAggregator,
        address fallbackAggregator,
        bool useFallbackIfErr,
        uint8 decimalsOvr,
        bool isVaultToken
    ) external onlyOwner {
        require(token != address(0), "OracleManager: invalid token");
        if (!isVaultToken) {
            require(primaryAggregator != address(0), "OracleManager: aggregator required for non-vault");
        }

        oracleConfigs[token] = OracleData({
            primaryAggregator: primaryAggregator,
            fallbackAggregator: fallbackAggregator,
            useFallbackIfError: useFallbackIfErr,
            decimalsOverride: decimalsOvr,
            isVaultToken: isVaultToken
        });

        emit OracleConfigUpdated(
            token,
            primaryAggregator,
            fallbackAggregator,
            useFallbackIfErr,
            decimalsOvr,
            isVaultToken
        );
    }

    function setVaultUnderlyingFeeds(
        address vaultToken,
        address token0Agg,
        address token1Agg,
        uint8 token0Dec,
        uint8 token1Dec
    ) external onlyOwner {
        require(vaultToken != address(0), "OracleManager: invalid vaultToken");

        vaultFeeds[vaultToken] = VaultUnderlyingFeeds({
            token0Aggregator: token0Agg,
            token1Aggregator: token1Agg,
            token0Decimals: token0Dec,
            token1Decimals: token1Dec,
            exists: true
        });

        emit VaultUnderlyingFeedsUpdated(
            vaultToken,
            token0Agg,
            token1Agg,
            token0Dec,
            token1Dec
        );
    }

    function getPrice(address token) external view returns (uint256 price, uint8 decimals) {
        OracleData memory cfg = oracleConfigs[token];
        require(cfg.primaryAggregator != address(0) || cfg.isVaultToken, "OracleManager: no aggregator/vault logic");

        if (!cfg.isVaultToken) {
            (price, decimals) = _getPriceFromConfig(cfg);
        } else {
            VaultUnderlyingFeeds memory vf = vaultFeeds[token];
            require(vf.exists, "OracleManager: vault feeds not set");
            (price, decimals) = _computeVaultTokenPrice(token, vf);
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _getPriceFromConfig(OracleData memory cfg)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        (bool okPrimary, uint256 p, uint8 d) = _tryGetChainlinkPrice(cfg.primaryAggregator, cfg.decimalsOverride);
        if (!okPrimary && cfg.useFallbackIfError && cfg.fallbackAggregator != address(0)) {
            (bool okFallback, uint256 pFallback, uint8 dFallback) =
                _tryGetChainlinkPrice(cfg.fallbackAggregator, cfg.decimalsOverride);
            require(okFallback, "OracleManager: fallback aggregator fail");
            return (pFallback, dFallback);
        }
        require(okPrimary, "OracleManager: primary aggregator fail");
        return (p, d);
    }

    struct AggregatorPair {
        address agg0;
        address agg1;
        uint8 dec0;
        uint8 dec1;
    }

    struct PositionResult {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    function _computeVaultTokenPrice(address vaultToken, VaultUnderlyingFeeds memory vf)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        (uint256 totalShares, uint256 tokenId, address posMgr) = _fetchVaultInfo(vaultToken);

        PositionResult memory pos = _fetchPositionData(posMgr, tokenId);

        (uint160 sqrtPriceX96, int24 tick) = _getPoolSqrtAndTick(IVaultToken(vaultToken).v3Pool());
        (uint256 amtActive0, uint256 amtActive1) = _computeLiquidityAmounts(
            sqrtPriceX96,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity
        );

        uint256 amt0 = amtActive0 + pos.owed0;
        uint256 amt1 = amtActive1 + pos.owed1;

        AggregatorPair memory ap = AggregatorPair({
            agg0: vf.token0Aggregator,
            agg1: vf.token1Aggregator,
            dec0: vf.token0Decimals,
            dec1: vf.token1Decimals
        });

        uint256 totalValue = _convertVaultTokensToValue(amt0, amt1, ap);

        price = totalValue / (totalShares == 0 ? 1 : totalShares);
        decimals = 8;
    }

    function _fetchVaultInfo(address vaultToken)
        internal
        view
        returns (uint256 totalShares, uint256 tokenId, address posMgr)
    {
        IVaultToken v = IVaultToken(vaultToken);
        totalShares = v.totalSupply();
        require(totalShares > 0, "OracleManager: vault totalSupply=0");
        tokenId = v.vaultTokenId();
        require(tokenId != 0, "OracleManager: no NFT in vault");
        posMgr = v.positionManager();
        require(posMgr != address(0), "OracleManager: invalid positionMgr");
    }

    function _fetchPositionData(address posMgr, uint256 tokenId)
        internal
        view
        returns (PositionResult memory pos)
    {
        (bool success, bytes memory data) = posMgr.staticcall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId)
        );
        require(success, _getRevertMsg(data));

        (
            ,
            ,
            pos.token0,
            pos.token1,
            ,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity,
            ,
            ,
            pos.owed0,
            pos.owed1
        ) = abi.decode(
            data,
            (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
        );
    }

    function _getPoolSqrtAndTick(address poolAddr) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        require(poolAddr != address(0), "OracleManager: invalid pool");
        (bool success, bytes memory data) = poolAddr.staticcall(
            abi.encodeWithSelector(IUniswapV3Pool.slot0.selector)
        );
        require(success, _getRevertMsg(data));
        (sqrtPriceX96, tick, , , , , ) = abi.decode(data, (uint160, int24, uint16, uint16, uint16, uint8, bool));
    }

    function _computeLiquidityAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amt0, uint256 amt1) {
        if (liquidity == 0) {
            return (0, 0);
        }
        uint160 sqrtLower = TickMathLocal.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMathLocal.getSqrtRatioAtTick(tickUpper);

        (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            liquidity
        );
    }

    function _convertVaultTokensToValue(
        uint256 amt0,
        uint256 amt1,
        AggregatorPair memory ap
    ) internal view returns (uint256) {
        uint256 val0 = _convertToAggregatorValue(amt0, ap.agg0, ap.dec0);
        uint256 val1 = _convertToAggregatorValue(amt1, ap.agg1, ap.dec1);
        return val0 + val1;
    }

    function _convertToAggregatorValue(
        uint256 amt,
        address aggregatorAddr,
        uint8 decimalsOvr
    ) internal view returns (uint256) {
        if (amt == 0 || aggregatorAddr == address(0)) {
            return 0;
        }
        (bool ok, uint256 p, uint8 d) = _tryGetChainlinkPrice(aggregatorAddr, decimalsOvr);
        require(ok, "OracleManager: aggregator fail in _convertToAggregatorValue");
        return (amt * p) / (10 ** d);
    }

    function _tryGetChainlinkPrice(address aggregator, uint8 decimalsOvr)
        internal
        view
        returns (bool success, uint256 price, uint8 decimals)
    {
        if (aggregator == address(0)) {
            return (false, 0, 0);
        }
        bytes memory payload = abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector);
        (bool callSuccess, bytes memory returnData) = aggregator.staticcall(payload);
        if (!callSuccess || returnData.length < 160) {
            return (false, 0, 0);
        }
        ( , int256 answer, , , ) = abi.decode(returnData, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0) {
            return (false, 0, 0);
        }

        uint8 aggDecimals = decimalsOvr;
        if (aggDecimals == 0) {
            (bool decSuccess, bytes memory decData) = aggregator.staticcall(
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector)
            );
            if (!decSuccess || decData.length < 32) {
                return (false, 0, 0);
            }
            aggDecimals = abi.decode(decData, (uint8));
        }
        return (true, uint256(answer), aggDecimals);
    }

    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "OracleManager: call reverted w/o msg";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
