// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title FixedPoint96Local
 * @notice Provides the fixed-point Q96 constant, used in Uniswap V3 math.
 * @dev This local version is patched to compile cleanly under Solidity ^0.8.17,
 *      removing the older <0.8.0 requirement.
 */
library FixedPoint96Local {
    /// @dev The resolution for the fixed-point numbers.
    uint8 internal constant RESOLUTION = 96;

    /// @dev The Q96 constant equals 2^96, which is central to Uniswap V3 math.
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96
}
