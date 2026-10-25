// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a Circle reports to the AjoScore registry.
interface IAjoScore {
    function registerCircle(address circle) external;
    function recordPayment(address member, uint256 amount) external;
    function recordMissed(address member) external;
    function recordCompletion(address member) external;
    function scoreOf(address member) external view returns (uint256);
}
