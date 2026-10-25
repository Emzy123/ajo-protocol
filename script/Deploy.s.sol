// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {AjoScore} from "../src/AjoScore.sol";
import {CircleFactory} from "../src/CircleFactory.sol";
import {IAjoScore} from "../src/interfaces/IAjoScore.sol";

/// forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --account deployer --broadcast --verify
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        MockUSDC usdc = new MockUSDC();
        MockYieldVault vault = new MockYieldVault(IERC20(address(usdc)));
        AjoScore score = new AjoScore(deployer);
        CircleFactory factory =
            new CircleFactory(IERC20(address(usdc)), IERC4626(address(vault)), IAjoScore(address(score)));
        score.setFactory(address(factory));

        vm.stopBroadcast();

        console2.log("MockUSDC      ", address(usdc));
        console2.log("MockYieldVault", address(vault));
        console2.log("AjoScore      ", address(score));
        console2.log("CircleFactory ", address(factory));
    }
}
