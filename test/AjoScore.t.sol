// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AjoScore} from "../src/AjoScore.sol";

contract AjoScoreTest is Test {
    AjoScore score;
    address factory = makeAddr("factory");
    address circle = makeAddr("circle");
    address user = makeAddr("user");

    function setUp() public {
        score = new AjoScore(address(this));
        score.setFactory(factory);
        vm.prank(factory);
        score.registerCircle(circle);
    }

    function test_FactoryCanOnlyBeSetOnce() public {
        vm.expectRevert(AjoScore.FactoryAlreadySet.selector);
        score.setFactory(address(1));
    }

    function test_OnlyOwnerSetsFactory() public {
        AjoScore fresh = new AjoScore(address(this));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        fresh.setFactory(user);
    }

    function test_OnlyFactoryRegistersCircles() public {
        vm.expectRevert(AjoScore.NotFactory.selector);
        score.registerCircle(address(this));
    }

    function test_OnlyCirclesWrite() public {
        vm.expectRevert(AjoScore.NotCircle.selector);
        score.recordPayment(user, 100e6);
        vm.expectRevert(AjoScore.NotCircle.selector);
        score.recordMissed(user);
        vm.expectRevert(AjoScore.NotCircle.selector);
        score.recordCompletion(user);
    }

    function test_NoHistoryIsZero() public view {
        assertEq(score.scoreOf(user), 0);
        assertFalse(score.hasHistory(user));
    }

    function test_ScoreFormula() public {
        vm.startPrank(circle);
        for (uint256 i; i < 5; ++i) {
            score.recordPayment(user, 100e6);
        }
        score.recordCompletion(user);
        vm.stopPrank();
        assertEq(score.scoreOf(user), 600); // 500 + 5*10 + 50

        vm.prank(circle);
        score.recordMissed(user);
        assertEq(score.scoreOf(user), 500);

        AjoScore.Record memory r = score.recordOf(user);
        assertEq(r.onTimePayments, 5);
        assertEq(r.missedPayments, 1);
        assertEq(r.circlesCompleted, 1);
        assertEq(r.totalContributed, 500e6);
    }

    function test_ScoreClampsAtZeroAndMax() public {
        vm.startPrank(circle);
        for (uint256 i; i < 6; ++i) {
            score.recordMissed(user);
        }
        assertEq(score.scoreOf(user), 0);

        address star = makeAddr("star");
        for (uint256 i; i < 100; ++i) {
            score.recordPayment(star, 1e6);
        }
        vm.stopPrank();
        assertEq(score.scoreOf(star), 1000);
    }
}
