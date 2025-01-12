// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./FullMathLocal.sol";
import "./TickMathLocal.sol";
import "./FixedPoint96Local.sol";

/**
 * @title LiquidityAmountsLocal
 * @notice Provides functions for computing token0 and token1 amounts from liquidity,
 *         and liquidity from token0 and token1 amounts, adapted from Uniswap V3's
 *         LiquidityAmounts library to compile under Solidity ^0.8.17.
 */
library LiquidityAmountsLocal {
    using FullMathLocal for uint256;

    /**
     * @notice Computes the amount of liquidity received for a given amount of token0 and price range
     * @param sqrtRatioAX96 A Q96.96 sqrt price representing the first tick boundary
     * @param sqrtRatioBX96 A Q96.96 sqrt price representing the second tick boundary
     * @param amount0 The token0 amount being sent in
     * @return liquidity The amount of returned liquidity
     */
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        // Calculate liquidity = amount0 * (sqrtRatioA * sqrtRatioB) / (sqrtRatioB - sqrtRatioA)
        // all in Q96.96 fixed point
        // cast to uint256 for safety
        uint256 intermediate = uint256(sqrtRatioAX96).mulDiv(sqrtRatioBX96, FixedPoint96Local.Q96);
        uint256 liq = amount0.mulDiv(intermediate, uint256(sqrtRatioBX96) - sqrtRatioAX96);
        require(liq <= type(uint128).max, "LiquidityAmountsLocal: overflow");
        liquidity = uint128(liq);
    }

    /**
     * @notice Computes the amount of liquidity received for a given amount of token1 and price range
     * @param sqrtRatioAX96 A Q96.96 sqrt price representing the first tick boundary
     * @param sqrtRatioBX96 A Q96.96 sqrt price representing the second tick boundary
     * @param amount1 The token1 amount being sent in
     * @return liquidity The amount of returned liquidity
     */
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        // liquidity = amount1 * Q96 / (sqrtRatioB - sqrtRatioA)
        uint256 liq = amount1.mulDiv(FixedPoint96Local.Q96, uint256(sqrtRatioBX96) - sqrtRatioAX96);
        require(liq <= type(uint128).max, "LiquidityAmountsLocal: overflow");
        liquidity = uint128(liq);
    }

    /**
     * @notice Computes the maximum amount of liquidity received for given amounts of token0 and token1
     *         and the prices at the tick boundaries
     * @param sqrtRatioAX96 A Q96.96 sqrt price representing the first tick boundary
     * @param sqrtRatioBX96 A Q96.96 sqrt price representing the second tick boundary
     * @param amount0 The token0 amount
     * @param amount1 The token1 amount
     * @return liquidity The maximum liquidity that can be held by the position
     */
    function getLiquidityForAmounts(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint160 sqrtRatioX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // If current price is below the price range, all liquidity is in token0
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // If current price is within the price range, some of both token0 and token1
            uint128 liq0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liq1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liq0 < liq1 ? liq0 : liq1;
        } else {
            // If current price is above the price range, all liquidity is in token1
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /**
     * @notice Computes the token0 and token1 value for a given amount of liquidity between two prices
     * @param sqrtRatioX96 The current sqrt price
     * @param sqrtRatioAX96 The lower sqrt price boundary
     * @param sqrtRatioBX96 The upper sqrt price boundary
     * @param liquidity The liquidity being valued
     * @return amount0 The amount of token0
     * @return amount1 The amount of token1
     */
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
            // If current price is below the price range
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
            amount1 = 0;
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // Current price is within the price range
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            // Current price is above the price range
            amount0 = 0;
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    /**
     * @dev Helper function that returns how much token0 corresponds to the given liquidity between two sqrt prices
     */
    function getAmount0ForLiquidity(
        uint160 sqrtRatioLowerX96,
        uint160 sqrtRatioUpperX96,
        uint128 liquidity
    ) private pure returns (uint256) {
        // difference of the sqrt prices
        uint256 numerator1 = uint256(liquidity) << FixedPoint96Local.RESOLUTION;
        uint256 numerator2 = uint256(sqrtRatioUpperX96) - uint256(sqrtRatioLowerX96);

        return
            numerator1.mulDiv(numerator2, uint256(sqrtRatioUpperX96))
            / uint256(sqrtRatioLowerX96);
    }

    /**
     * @dev Helper function that returns how much token1 corresponds to the given liquidity between two sqrt prices
     */
    function getAmount1ForLiquidity(
        uint160 sqrtRatioLowerX96,
        uint160 sqrtRatioUpperX96,
        uint128 liquidity
    ) private pure returns (uint256) {
        return uint256(liquidity).mulDiv(
            uint256(sqrtRatioUpperX96) - uint256(sqrtRatioLowerX96),
            FixedPoint96Local.Q96
        );
    }
}
