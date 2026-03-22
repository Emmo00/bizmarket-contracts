// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// 100 == 1%, 500 == 5%, 10000 == 100%, etc.

library Percentage {
    /// @notice Calculates a percentage of a given value where the percentage is represented in basis points.
    /// @dev The percentage is divided by 10000 because the input percentage is assumed to be in basis points (bps),
    /// where 1 basis point = 0.01% (1/100th of 1%). Therefore, 10000 basis points = 100%.
    /// For example: percentage=5000 represents 50%, percentage=100 represents 1%, percentage=1 represents 0.01%.
    /// @param value The base value to calculate the percentage from.
    /// @param percentage The percentage in basis points (0-10000).
    /// @return The calculated percentage of the value.
    function calculate(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return (value * percentage) / 10000;
    }

    /// @notice Increases a value by a given percentage.
    /// @param value The base value to increase.
    /// @param percentage The percentage in basis points (0-10000).
    /// @return The increased value.
    function increaseByPercentage(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return value + calculate(value, percentage);
    }

    /// @notice Decreases a value by a given percentage.
    /// @param value The base value to decrease.
    /// @param percentage The percentage in basis points (0-10000).
    /// @return The decreased value.
    function decreaseByPercentage(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return value - calculate(value, percentage);
    }
}
