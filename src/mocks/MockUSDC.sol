// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Testnet-only USDC stand-in: 6 decimals and an open faucet.
contract MockUSDC is ERC20 {
    uint256 public constant FAUCET_LIMIT = 10_000e6; // max per mint call

    error FaucetLimit();

    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint up to 10,000 mUSDC per call (testnet faucet).
    function mint(address to, uint256 amount) external {
        if (amount > FAUCET_LIMIT) revert FaucetLimit();
        _mint(to, amount);
    }
}
