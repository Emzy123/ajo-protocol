// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockYieldVault
/// @notice The testnet yield adapter: a plain ERC-4626 vault over USDC.
///         On mainnet a Circle points at a real ERC-4626 vault (for example an
///         Aave or Morpho USDC vault) instead; nothing in Circle changes.
///         `simulateYield` lets a demo push interest in so share price rises.
contract MockYieldVault is ERC4626 {
    using SafeERC20 for IERC20;

    event YieldSimulated(address indexed from, uint256 amount);

    constructor(IERC20 asset_) ERC20("Ajo Yield Vault", "ajoVault") ERC4626(asset_) {}

    /// @notice Donate `amount` of the asset to the vault, raising the value of every share.
    function simulateYield(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldSimulated(msg.sender, amount);
    }
}
