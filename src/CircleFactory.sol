// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Circle} from "./Circle.sol";
import {IAjoScore} from "./interfaces/IAjoScore.sol";

/// @title CircleFactory
/// @notice Deploys savings circles that share one token, one yield vault and one AjoScore.
///         Every circle it creates is registered with AjoScore so it can write scores.
contract CircleFactory {
    IERC20 public immutable token;
    IERC4626 public immutable vault;
    IAjoScore public immutable score;

    address[] internal _circles;
    mapping(address => bool) public isCircle;
    mapping(address => address[]) internal _circlesByCreator;

    event CircleCreated(
        address indexed circle,
        address indexed creator,
        string name,
        uint256 contribution,
        uint256 maxMembers,
        uint256 roundDuration,
        uint256 maxDiscountBps
    );

    error VaultAssetMismatch();

    constructor(IERC20 token_, IERC4626 vault_, IAjoScore score_) {
        if (address(vault_) != address(0) && vault_.asset() != address(token_)) revert VaultAssetMismatch();
        token = token_;
        vault = vault_;
        score = score_;
    }

    /// @param name           display name, e.g. "Lagos-Dubai Rent Circle"
    /// @param contribution   per member per round, in token base units (100 USDC = 100e6)
    /// @param maxMembers     seats, which is also the number of rounds (2..20)
    /// @param roundDuration  seconds per round (>= 60)
    /// @param maxDiscountBps cap on a bid as basis points of the full pot (<= 5000)
    function createCircle(
        string calldata name,
        uint256 contribution,
        uint256 maxMembers,
        uint256 roundDuration,
        uint256 maxDiscountBps
    ) external returns (address circle) {
        Circle c = new Circle(
            Circle.Config({
                name: name,
                token: token,
                vault: vault,
                score: score,
                creator: msg.sender,
                contribution: contribution,
                maxMembers: maxMembers,
                roundDuration: roundDuration,
                maxDiscountBps: maxDiscountBps
            })
        );
        circle = address(c);
        _circles.push(circle);
        isCircle[circle] = true;
        _circlesByCreator[msg.sender].push(circle);
        score.registerCircle(circle);
        emit CircleCreated(circle, msg.sender, name, contribution, maxMembers, roundDuration, maxDiscountBps);
    }

    function circleCount() external view returns (uint256) {
        return _circles.length;
    }

    function allCircles() external view returns (address[] memory) {
        return _circles;
    }

    function circlesByCreator(address creator) external view returns (address[] memory) {
        return _circlesByCreator[creator];
    }
}
