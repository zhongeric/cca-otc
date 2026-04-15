// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal interface for interacting with the Continuous Clearing Auction
interface ICCA {
    function sweepCurrency() external;
    function sweepUnsoldTokens() external;
    function isGraduated() external view returns (bool);
}
