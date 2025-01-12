// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title FullMathLocal
 * @notice A 512-bit math library for multiplication and division, supporting
 *         cases that can overflow a 256-bit intermediate.
 * @dev    Adapted from Uniswap V3's FullMath to compile under Solidity ^0.8.17. 
 *         This version is MIT-licensed for demonstration purposes.
 */
library FullMathLocal {
    /**
     * @notice Calculates floor(a * b / denominator) with full precision.
     *         Reverts if the result overflows a uint256 or if denominator == 0.
     * @param a The multiplicand
     * @param b The multiplier
     * @param denominator The divisor
     * @return result The 256-bit result
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // prod0 is the least significant 256 bits of the product
            // prod1 is the most significant 256 bits of the product
            uint256 prod0; // lower 256 bits
            uint256 prod1; // upper 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 => 256
            if (prod1 == 0) {
                require(denominator > 0, "FullMathLocal: denom=0");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2^256.
            // Also prevents denominator == 0
            require(denominator > prod1, "FullMathLocal: overflow");

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            // Compute remainder using mulmod.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract remainder from [prod1 prod0].
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (type(uint256).max - denominator + 1) & denominator;
            // In other words, twos = 2^n where n is the number of least-significant 0 bits in denominator.

            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Shift in bits from prod1 into prod0.
                // If prod1 is shifted by n bits, then effectively we're dividing the 512-bit number by 2^n.
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256
            // Now that denominator is odd, it has an inverse under modulo 2^256.
            // Compute the inverse by starting with a seed that is correct for four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inv = (3 * denominator) ^ 2;

            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel’s lifting lemma, this also works in modular arithmetic, doubling correct bits in each step.
            assembly {
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^8
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^16
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^32
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^64
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^128
                inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2^256
            }

            // Multiply the result by the inverse of denominator mod 2^256.
            // This effectively performs the final division step, leaving us with
            // floor([prod1 prod0] / denominator).
            result = prod0 * inv;
            return result;
        }
    }

    /**
     * @notice Calculates ceil(a * b / denominator) with full precision.
     *         Reverts if the result overflows a uint256 or if denominator == 0.
     * @param a The multiplicand
     * @param b The multiplier
     * @param denominator The divisor
     * @return result The 256-bit result
     */
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        unchecked {
            // mulmod returns remainder
            if (mulmod(a, b, denominator) > 0) {
                require(result < type(uint256).max, "FullMathLocal: overflow");
                result++;
            }
        }
    }
}
