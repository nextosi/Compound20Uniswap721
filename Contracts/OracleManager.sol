// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* ---------------------------------------------------------------------
 * 1) Chainlink aggregator interface (v1.6.0, ^0.8)
 * --------------------------------------------------------------------- */
import "https://github.com/smartcontractkit/chainlink/blob/v1.6.0/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/* ---------------------------------------------------------------------
 * 2) OpenZeppelin v4.8.3: Ownable for ^0.8.x
 * --------------------------------------------------------------------- */
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.3/contracts/access/Ownable.sol";

/* ---------------------------------------------------------------------
 * 3) Local libraries, all ^0.8.x, with subfunctions to avoid stack-too-deep
 * --------------------------------------------------------------------- */
library FixedPoint96Local {
    uint8   internal constant RESOLUTION = 96;
    uint256 internal constant Q96        = 0x1000000000000000000000000; // 2^96
}

/**
 * @dev A “split” version of FullMath that breaks out parts of mulDiv
 *      into subfunctions, reducing local variable usage in a single scope.
 */
library FullMathLocal {
    /**
     * @notice 512-bit multiply of (a * b) => (prod1, prod0)
     *         Returns the lower and upper 256 bits of the product.
     */
    function _fullMul512(uint256 a, uint256 b)
        private
        pure
        returns (uint256 prod0, uint256 prod1)
    {
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0  := mul(a, b)
            prod1  := sub(sub(mm, prod0), lt(mm, prod0))
        }
    }

    /**
     * @notice Factor out powers of two from the denominator.  
     * @return newDenominator The denominator after dividing out 2^n
     * @return twos The 2^n factor in the low bits (used for shifting prod0)
     */
    function _factorDenominatorTwos(uint256 denominator)
        private
        pure
        returns (uint256 newDenominator, uint256 twos)
    {
        // “twos” is largest power-of-two divisor of denominator
        // (type(uint256).max - denominator + 1) & denominator
        twos = (type(uint256).max - denominator + 1) & denominator;
        assembly {
            newDenominator := div(denominator, twos)
        }
    }

    /**
     * @notice Computes modular inverse of the denominator under 2^256
     */
    function _invertDenominator(uint256 d) private pure returns (uint256 inv) {
        // “inv” is a seed correct for 4 bits
        inv = (3 * d) ^ 2;
        // Perform 6 iterations of Newton–Raphson to get full 2^256 inverse
        assembly {
            inv := mul(inv, sub(2, mul(d, inv)))
            inv := mul(inv, sub(2, mul(d, inv)))
            inv := mul(inv, sub(2, mul(d, inv)))
            inv := mul(inv, sub(2, mul(d, inv)))
            inv := mul(inv, sub(2, mul(d, inv)))
            inv := mul(inv, sub(2, mul(d, inv)))
        }
    }

    /**
     * @notice Calculates floor(a * b / denominator) with full precision (512-bit).
     *         Reverts if denominator == 0 or overflows a uint256.
     */
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            (uint256 prod0, uint256 prod1) = _fullMul512(a, b);

            if (prod1 == 0) {
                // Fits in 256 bits => simple path
                require(denominator > 0, "FullMathLocal: denom=0");
                assembly { result := div(prod0, denominator) }
                return result;
            }
            require(denominator > prod1, "FullMathLocal: overflow");
            
            // subtract remainder from [prod1 prod0] to make it divisible
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1     := sub(prod1, gt(remainder, prod0))
                prod0     := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            (uint256 newDenominator, uint256 twos) = _factorDenominatorTwos(denominator);
            assembly {
                // divide prod0 by twos
                prod0 := div(prod0, twos)
                // shift in bits from prod1
                twos  := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert the denominator mod 2^256
            uint256 inv = _invertDenominator(newDenominator);

            // final multiply => floor([prod1 prod0]/denominator)
            result = prod0 * inv;
        }
    }

    /**
     * @notice Same as mulDiv but rounds up if remainder != 0
     */
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(a, b, denominator);
        unchecked {
            // if remainder != 0 => add 1
            if (mulmod(a, b, denominator) > 0) {
                require(result < type(uint256).max, "FullMathLocal: overflow");
                result++;
            }
        }
    }
}

/**
 * @dev Minimal TickMath with int24->uint256 fix. 
 *      We break out the ratio calc in smaller steps if needed.
 */
library TickMathLocal {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        int256 t = int256(tick);
        uint256 absTick = t < 0 ? uint256(-t) : uint256(t);

        // ratio is in Q128.128 format
        uint256 ratio = 0x100000000000000000000000000000000;

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

        // invert if tick>0
        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }
        // downshift Q128.128 => Q128.96
        uint256 shifted = ratio >> 32;
        require(shifted <= type(uint160).max, "Price overflow");
        sqrtPriceX96 = uint160(shifted);
    }
}

/**
 * @dev Minimal version of LiquidityAmounts, referencing FullMathLocal + TickMathLocal,
 *      split as needed to avoid deep local variables.
 */
library LiquidityAmountsLocal {
    using FullMathLocal for uint256;

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // all token0
            amount0 = _getAmount0(sqrtRatioAX96, sqrtRatioBX96, liquidity);
            amount1 = 0;
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // partial range
            amount0 = _getAmount0(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = _getAmount1(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            // all token1
            amount0 = 0;
            amount1 = _getAmount1(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    function _getAmount0(
        uint160 sqrtRatioLowerX96,
        uint160 sqrtRatioUpperX96,
        uint128 liquidity
    ) private pure returns (uint256) {
        // numerator1 = liquidity << 96
        uint256 numerator1 = uint256(liquidity) << FixedPoint96Local.RESOLUTION;
        // numerator2 = (sqrtRatioUpperX96 - sqrtRatioLowerX96)
        uint256 numerator2 = uint256(sqrtRatioUpperX96) - uint256(sqrtRatioLowerX96);
        // multiply => then divide => then divide
        return numerator1.mulDiv(numerator2, sqrtRatioUpperX96) / sqrtRatioLowerX96;
    }

    function _getAmount1(
        uint160 sqrtRatioLowerX96,
        uint160 sqrtRatioUpperX96,
        uint128 liquidity
    ) private pure returns (uint256) {
        // (liquidity * (sqrtRatioUpper - sqrtRatioLower)) / Q96
        return uint256(liquidity).mulDiv(
            uint256(sqrtRatioUpperX96) - uint256(sqrtRatioLowerX96),
            FixedPoint96Local.Q96
        );
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
            int24  tickLower,
            int24  tickUpper,
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
            int24  tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8  feeProtocol,
            bool   unlocked
        );
}

/* ---------------------------------------------------------------------
 * OracleManager
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

    // ------------------ Configuration ------------------

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

    // ------------------ Public Getter ------------------

    /**
     * @notice Return the price for `token` (or the Uniswap-based vault),
     *         plus the aggregator decimals.
     */
    function getPrice(address token) external view returns (uint256 price, uint8 decimals) {
        OracleData memory cfg = oracleConfigs[token];
        require(
            cfg.primaryAggregator != address(0) || cfg.isVaultToken,
            "OracleManager: no aggregator/vault logic"
        );

        if (!cfg.isVaultToken) {
            (price, decimals) = _getPriceFromChainlink(cfg);
        } else {
            VaultUnderlyingFeeds memory vf = vaultFeeds[token];
            require(vf.exists, "OracleManager: vault feeds not set");
            (price, decimals) = _computeVaultPrice(token, vf);
        }
    }

    // ------------------ Internal: Chainlink logic ------------------

    function _getPriceFromChainlink(OracleData memory cfg)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        (bool okPrimary, uint256 p, uint8 d) = _tryGetChainlinkPrice(cfg.primaryAggregator, cfg.decimalsOverride);
        if (!okPrimary && cfg.useFallbackIfError && cfg.fallbackAggregator != address(0)) {
            (bool okFallback, uint256 pf, uint8 df) =
                _tryGetChainlinkPrice(cfg.fallbackAggregator, cfg.decimalsOverride);
            require(okFallback, "OracleManager: fallback aggregator fail");
            return (pf, df);
        }
        require(okPrimary, "OracleManager: primary aggregator fail");
        return (p, d);
    }

    function _tryGetChainlinkPrice(address aggregator, uint8 decimalsOvr)
        internal
        view
        returns (bool success, uint256 price, uint8 decimals)
    {
        if (aggregator == address(0)) {
            return (false, 0, 0);
        }
        // aggregator.latestRoundData()
        try AggregatorV3Interface(aggregator).latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256,
            uint80
        ) {
            if (answer <= 0) {
                return (false, 0, 0);
            }
            uint8 aggDecimals;
            if (decimalsOvr == 0) {
                try AggregatorV3Interface(aggregator).decimals() returns (uint8 d) {
                    aggDecimals = d;
                } catch {
                    return (false, 0, 0);
                }
            } else {
                aggDecimals = decimalsOvr;
            }
            return (true, uint256(answer), aggDecimals);
        } catch {
            return (false, 0, 0);
        }
    }

    // ------------------ Internal: Vault logic ------------------

    /**
     * @dev We break it up into multiple subfunctions to avoid stack-too-deep.
     */
    function _computeVaultPrice(address vaultToken, VaultUnderlyingFeeds memory vf)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        VaultInfo memory vi = _fetchVaultInfo(vaultToken);
        if (vi.totalShares == 0) {
            return (0, 8);
        }
        if (vi.pool == address(0)) {
            return (0, 8);
        }

        (uint256 amt0, uint256 amt1) = _calcVaultAmounts(vi);
        uint256 totalUsd = _convertPairToUsd(amt0, amt1, vf);

        price    = totalUsd / vi.totalShares;
        decimals = 8;
    }

    struct VaultInfo {
        uint256 totalShares;
        uint256 tokenId;
        address posMgr;
        address pool;
        int24  tickLower;
        int24  tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
        uint160 sqrtPriceX96;
    }

    function _fetchVaultInfo(address vaultToken) internal view returns (VaultInfo memory vi) {
        IVaultToken v = IVaultToken(vaultToken);
        vi.totalShares = v.totalSupply();
        vi.tokenId     = v.vaultTokenId();
        vi.posMgr      = v.positionManager();
        require(vi.posMgr != address(0), "OracleManager: invalid posMgr");
        vi.pool = v.v3Pool();

        if (vi.tokenId != 0) {
            (
                ,
                ,
                ,
                ,
                ,
                vi.tickLower,
                vi.tickUpper,
                vi.liquidity,
                ,
                ,
                vi.owed0,
                vi.owed1
            ) = INonfungiblePositionManager(vi.posMgr).positions(vi.tokenId);
        }
        if (vi.pool != address(0)) {
            (vi.sqrtPriceX96, , , , , , ) = IUniswapV3Pool(vi.pool).slot0();
        }
    }

    function _calcVaultAmounts(VaultInfo memory vi)
        internal
        pure
        returns (uint256 amt0, uint256 amt1)
    {
        if (vi.liquidity > 0 && vi.sqrtPriceX96 != 0) {
            uint160 sqrtLower = TickMathLocal.getSqrtRatioAtTick(vi.tickLower);
            uint160 sqrtUpper = TickMathLocal.getSqrtRatioAtTick(vi.tickUpper);
            (amt0, amt1) = LiquidityAmountsLocal.getAmountsForLiquidity(
                vi.sqrtPriceX96,
                sqrtLower,
                sqrtUpper,
                vi.liquidity
            );
        }
        amt0 += vi.owed0;
        amt1 += vi.owed1;
    }

    function _convertPairToUsd(uint256 amt0, uint256 amt1, VaultUnderlyingFeeds memory vf)
        internal
        view
        returns (uint256 totalUsd)
    {
        uint256 val0 = _convertToUsd(amt0, vf.token0Aggregator, vf.token0Decimals);
        uint256 val1 = _convertToUsd(amt1, vf.token1Aggregator, vf.token1Decimals);
        totalUsd = val0 + val1;
    }

    function _convertToUsd(uint256 amt, address aggregator, uint8 decimalsOvr)
        internal
        view
        returns (uint256)
    {
        if (amt == 0 || aggregator == address(0)) return 0;
        (bool ok, uint256 p, uint8 d) = _tryGetChainlinkPrice(aggregator, decimalsOvr);
        require(ok, "OracleManager: aggregator fail in _convertToUsd");
        return (amt * p) / (10 ** d);
    }
}
