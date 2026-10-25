// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {AjoScore} from "../src/AjoScore.sol";
import {CircleFactory} from "../src/CircleFactory.sol";
import {Circle} from "../src/Circle.sol";
import {IAjoScore} from "../src/interfaces/IAjoScore.sol";

contract CircleTest is Test {
    MockUSDC usdc;
    MockYieldVault vault;
    AjoScore score;
    CircleFactory factory;
    Circle circle;

    uint256 constant C = 100e6; // 100 USDC per round
    uint256 constant N = 5; // 5 seats = 5 rounds, pot = 500 USDC
    uint256 constant ROUND = 7 days;
    uint256 constant MAX_DISCOUNT_BPS = 2_000; // bids capped at 20% of the pot (100 USDC)
    uint256 constant START_BALANCE = 1_000e6;

    // Five friends in Lagos and Dubai
    address ada = makeAddr("ada"); // Lagos, needs rent early
    address bayo = makeAddr("bayo"); // Lagos
    address chidi = makeAddr("chidi"); // Dubai
    address dami = makeAddr("dami"); // Dubai
    address emeka = makeAddr("emeka"); // Lagos
    address[] friends;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockYieldVault(IERC20(address(usdc)));
        score = new AjoScore(address(this));
        factory = new CircleFactory(IERC20(address(usdc)), IERC4626(address(vault)), IAjoScore(address(score)));
        score.setFactory(address(factory));

        vm.prank(ada);
        circle = Circle(factory.createCircle("Lagos-Dubai Rent Circle", C, N, ROUND, MAX_DISCOUNT_BPS));

        friends = [ada, bayo, chidi, dami, emeka];
        for (uint256 i; i < N; ++i) {
            usdc.mint(friends[i], START_BALANCE);
            vm.prank(friends[i]);
            usdc.approve(address(circle), type(uint256).max);
        }
    }

    // ------------------------------------------------------------- helpers

    function _joinAll() internal {
        for (uint256 i; i < N; ++i) {
            vm.prank(friends[i]);
            circle.join();
        }
    }

    function _allContribute() internal {
        for (uint256 i; i < N; ++i) {
            vm.prank(friends[i]);
            circle.contribute();
        }
    }

    function _contributeExcept(address skip) internal {
        for (uint256 i; i < N; ++i) {
            if (friends[i] == skip) continue;
            vm.prank(friends[i]);
            circle.contribute();
        }
    }

    function _endRound() internal {
        vm.warp(circle.roundDeadline() + 1);
        circle.closeRound();
    }

    function _claimAll() internal {
        for (uint256 i; i < N; ++i) {
            if (circle.claimable(friends[i]) == 0) continue;
            vm.prank(friends[i]);
            circle.claim();
        }
    }

    function _totalFriendBalance() internal view returns (uint256 total) {
        for (uint256 i; i < N; ++i) {
            total += usdc.balanceOf(friends[i]);
        }
    }

    function _collateral(address a) internal view returns (uint256 c) {
        (,,,, c,) = circle.members(a);
    }

    function _debt(address a) internal view returns (uint256 d) {
        (,,,,, d) = circle.members(a);
    }

    function _missed(address a) internal view returns (uint32 m) {
        (,,, m,,) = circle.members(a);
    }

    // ---------------------------------------------------------------- mocks

    function test_MockUSDC_SixDecimalsAndFaucetLimit() public {
        assertEq(usdc.decimals(), 6);
        vm.expectRevert(MockUSDC.FaucetLimit.selector);
        usdc.mint(ada, 10_001e6);
    }

    // --------------------------------------------------------------- factory

    function test_Factory_RegistersCircle() public view {
        assertEq(factory.circleCount(), 1);
        assertTrue(factory.isCircle(address(circle)));
        assertTrue(score.isCircle(address(circle)));
        assertEq(circle.creator(), ada);
        assertEq(circle.factory(), address(factory));
        assertEq(factory.circlesByCreator(ada)[0], address(circle));
        assertEq(circle.potSize(), 500e6);
        assertEq(circle.maxDiscount(), 100e6);
        assertEq(circle.name(), "Lagos-Dubai Rent Circle");
    }

    function test_Factory_RejectsBadConfig() public {
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle("one seat", C, 1, ROUND, 0); // too few members
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle("crowd", C, 21, ROUND, 0); // too many members
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle("free", 0, N, ROUND, 0); // zero contribution
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle("flash", C, N, 59, 0); // round too short
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle("greedy", C, N, ROUND, 5_001); // discount cap above 50%
    }

    function test_Factory_RejectsVaultForOtherToken() public {
        MockUSDC other = new MockUSDC();
        MockYieldVault wrongVault = new MockYieldVault(IERC20(address(other)));
        vm.expectRevert(CircleFactory.VaultAssetMismatch.selector);
        new CircleFactory(IERC20(address(usdc)), IERC4626(address(wrongVault)), IAjoScore(address(score)));
    }

    // ----------------------------------------------------------------- join

    function test_Join_LocksCollateralAndStartsWhenFull() public {
        vm.prank(ada);
        circle.join();
        assertEq(uint256(circle.status()), uint256(Circle.Status.Open));
        assertEq(_collateral(ada), C);
        assertEq(usdc.balanceOf(ada), START_BALANCE - C);

        vm.prank(ada);
        vm.expectRevert(Circle.AlreadyMember.selector);
        circle.join();

        for (uint256 i = 1; i < N; ++i) {
            vm.prank(friends[i]);
            circle.join();
        }
        assertEq(uint256(circle.status()), uint256(Circle.Status.Active));
        assertEq(circle.currentRound(), 1);
        assertEq(circle.roundDeadline(), block.timestamp + ROUND);
        assertEq(circle.totalCollateral(), C * N);
        assertEq(vault.totalAssets(), C * N); // collateral is earning in the vault

        address late = makeAddr("late");
        vm.prank(late);
        vm.expectRevert(Circle.WrongStatus.selector);
        circle.join();
    }

    function test_Leave_RefundsAndKeepsJoinOrder() public {
        vm.prank(ada);
        circle.join();
        vm.prank(bayo);
        circle.join();
        vm.prank(chidi);
        circle.join();

        vm.prank(ada);
        circle.leave();
        assertEq(usdc.balanceOf(ada), START_BALANCE);
        address[] memory m = circle.getMembers();
        assertEq(m.length, 2);
        assertEq(m[0], bayo);
        assertEq(m[1], chidi);

        vm.prank(ada);
        vm.expectRevert(Circle.NotMember.selector);
        circle.leave();
    }

    // ---------------------------------------------------------- contribute

    function test_Contribute_DepositsAndBuildsScore() public {
        _joinAll();
        vm.prank(bayo);
        circle.contribute();
        assertTrue(circle.contributed(1, bayo));
        assertEq(circle.roundPot(), C);
        assertEq(vault.totalAssets(), C * N + C);
        assertEq(score.scoreOf(bayo), 510); // 500 base + 10 for one on-time payment

        vm.prank(bayo);
        vm.expectRevert(Circle.AlreadyContributed.selector);
        circle.contribute();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Circle.NotMember.selector);
        circle.contribute();

        vm.warp(circle.roundDeadline() + 1);
        vm.prank(chidi);
        vm.expectRevert(Circle.RoundOver.selector);
        circle.contribute();
    }

    function test_Contribute_NotBeforeStart() public {
        vm.prank(ada);
        circle.join();
        vm.prank(ada);
        vm.expectRevert(Circle.WrongStatus.selector);
        circle.contribute();
    }

    // ------------------------------------------------------------------ bid

    function test_Bid_Rules() public {
        _joinAll();

        vm.prank(ada);
        vm.expectRevert(Circle.MustContributeFirst.selector);
        circle.bid(10e6);

        _allContribute();

        vm.prank(ada);
        circle.bid(20e6);

        vm.prank(bayo);
        vm.expectRevert(Circle.BidTooLow.selector);
        circle.bid(20e6); // must beat the leader

        uint256 cap = circle.maxDiscount();
        vm.prank(bayo);
        vm.expectRevert(Circle.BidTooHigh.selector);
        circle.bid(cap + 1);

        vm.prank(bayo);
        circle.bid(30e6);
        assertEq(circle.highestBidder(), bayo);
        assertEq(circle.highestBid(), 30e6);

        vm.warp(circle.roundDeadline() + 1);
        vm.prank(chidi);
        vm.expectRevert(Circle.RoundOver.selector);
        circle.bid(40e6);
    }

    // --------------------------------------------- the demo story, end to end

    /// Ada needs rent early. She bids a 50 USDC discount for round 1's 500 USDC pot.
    /// She receives 450 now; Bayo, Chidi, Dami and Emeka each earn 12.5.
    function test_DemoStory_AdaBidsForRentAndOthersEarnDiscount() public {
        _joinAll();
        _allContribute();

        vm.prank(ada);
        circle.bid(50e6);

        uint256 adaBefore = usdc.balanceOf(ada);
        _endRound();

        assertEq(circle.roundWinner(1), ada);
        assertEq(usdc.balanceOf(ada) - adaBefore, 450e6);
        for (uint256 i = 1; i < N; ++i) {
            assertEq(circle.claimable(friends[i]), 12.5e6);
        }
        assertEq(circle.currentRound(), 2);

        // Bayo takes his 12.5 USDC straight away.
        uint256 bayoBefore = usdc.balanceOf(bayo);
        vm.prank(bayo);
        circle.claim();
        assertEq(usdc.balanceOf(bayo) - bayoBefore, 12.5e6);

        // Ada already won, so she can't bid again.
        _allContribute();
        vm.prank(ada);
        vm.expectRevert(Circle.AlreadyPaidOut.selector);
        circle.bid(1e6);
    }

    function test_NoBids_FallsBackToJoinOrder() public {
        _joinAll();
        _allContribute();
        _endRound();
        assertEq(circle.roundWinner(1), ada);

        _allContribute();
        _endRound();
        assertEq(circle.roundWinner(2), bayo);
    }

    function test_CloseRound_BeforeDeadlineReverts() public {
        _joinAll();
        vm.expectRevert(Circle.RoundStillOpen.selector);
        circle.closeRound();
    }

    // ---------------------------------------------------------------- slash

    function test_Slash_CollateralCoversMissedPayment() public {
        _joinAll();
        _contributeExcept(emeka);

        uint256 adaBefore = usdc.balanceOf(ada);
        _endRound();

        assertEq(_collateral(emeka), 0);
        assertEq(_missed(emeka), 1);
        assertEq(_debt(emeka), 0);
        assertEq(score.recordOf(emeka).missedPayments, 1);
        assertEq(score.scoreOf(emeka), 400); // 500 base - 100 for the miss
        // The pot is still whole because Emeka's collateral covered him.
        assertEq(usdc.balanceOf(ada) - adaBefore, 500e6);
        assertFalse(circle.isGoodStanding(emeka));
    }

    function test_Slash_MisserIsSkippedForNoBidPayout() public {
        _joinAll();
        // Ada is first in line but skips round 1: Bayo gets the pot instead.
        _contributeExcept(ada);
        _endRound();
        assertEq(circle.roundWinner(1), bayo);
    }

    function test_Slash_TopUpRestoresCollateral() public {
        _joinAll();
        _contributeExcept(emeka);
        _endRound();

        vm.prank(emeka);
        circle.topUpCollateral();
        assertEq(_collateral(emeka), C);

        vm.prank(emeka);
        vm.expectRevert(Circle.CollateralFull.selector);
        circle.topUpCollateral();
    }

    /// Emeka misses twice. The first miss eats his collateral; the second becomes debt,
    /// which is taken out of his own payout and shared with the members who paid.
    function test_Slash_SecondMissBecomesDebtRecoveredFromPayout() public {
        _joinAll();
        for (uint256 r = 1; r <= 2; ++r) {
            _contributeExcept(emeka);
            _endRound();
        }
        assertEq(_debt(emeka), C);

        for (uint256 r = 3; r <= N; ++r) {
            _allContribute();
            _endRound();
        }
        // Emeka was last in line; his 400 USDC round-5 pot lost 100 to his debt.
        assertEq(circle.roundWinner(N), emeka);
        assertEq(_debt(emeka), 0);
        assertEq(uint256(circle.status()), uint256(Circle.Status.Completed));

        _claimAll();
        // Four clean members share the 100 recovered: 25 each.
        assertEq(usdc.balanceOf(dami), START_BALANCE + 25e6);
        assertEq(_totalFriendBalance(), N * START_BALANCE); // nothing created or lost
        assertEq(score.recordOf(emeka).circlesCompleted, 0);
        assertEq(score.recordOf(dami).circlesCompleted, 1);
    }

    // ---------------------------------------------------------------- yield

    function test_Yield_SharedAtCompletion() public {
        _joinAll();
        for (uint256 r = 1; r <= N; ++r) {
            _allContribute();
            if (r == 2) {
                // 10 USDC of interest lands in the vault mid-circle
                usdc.mint(address(this), 10e6);
                usdc.approve(address(vault), 10e6);
                vault.simulateYield(10e6);
                assertApproxEqAbs(circle.accruedYield(), 10e6, 2);
            }
            _endRound();
        }
        _claimAll();
        for (uint256 i; i < N; ++i) {
            // everyone gets back 1,000 plus about 2 USDC of yield
            assertApproxEqAbs(usdc.balanceOf(friends[i]), START_BALANCE + 2e6, 5);
        }
        assertLe(usdc.balanceOf(address(circle)), 10); // only rounding dust left
    }

    // ------------------------------------------------------ full lifecycle

    function test_FullCircle_CompletesAndEveryoneWithdraws() public {
        _joinAll();
        // Round 1: Ada bids 50. Round 2: Chidi bids 25. Rounds 3-5: no bids.
        _allContribute();
        vm.prank(ada);
        circle.bid(50e6);
        _endRound();

        _allContribute();
        vm.prank(chidi);
        circle.bid(25e6);
        _endRound();

        for (uint256 r = 3; r <= N; ++r) {
            _allContribute();
            _endRound();
        }

        assertEq(uint256(circle.status()), uint256(Circle.Status.Completed));
        _claimAll();
        assertEq(usdc.balanceOf(address(circle)), 0);

        // Early winners pay for speed; late winners are paid for waiting.
        assertLt(usdc.balanceOf(ada), START_BALANCE);
        assertGt(usdc.balanceOf(emeka), START_BALANCE);
        assertEq(_totalFriendBalance(), N * START_BALANCE);

        for (uint256 i; i < N; ++i) {
            // 500 base + 5 on-time payments (50) + 1 completed circle (50)
            assertEq(score.scoreOf(friends[i]), 600);
        }
    }

    // ------------------------------------------------------------- fuzzing

    /// Whatever the bids and whoever skips, no money is created or lost.
    function testFuzz_MoneyIsConserved(uint256 bid1, uint256 bid2, uint8 skipperSeed) public {
        bid1 = bound(bid1, 1, circle.maxDiscount());
        bid2 = bound(bid2, 1, circle.maxDiscount());
        address skipper = friends[skipperSeed % N];
        _joinAll();

        _contributeExcept(skipper);
        address bidder1 = skipper == dami ? bayo : dami;
        vm.prank(bidder1);
        circle.bid(bid1);
        _endRound();

        _allContribute();
        address bidder2 = (bidder1 == bayo || skipper == bayo) ? chidi : bayo;
        if (bidder2 == bidder1) bidder2 = emeka;
        vm.prank(bidder2);
        circle.bid(bid2);
        _endRound();

        for (uint256 r = 3; r <= N; ++r) {
            _allContribute();
            _endRound();
        }
        _claimAll();
        uint256 left = usdc.balanceOf(address(circle)); // rounding dust only
        assertLe(left, N);
        assertEq(_totalFriendBalance() + left, N * START_BALANCE);
    }
}
