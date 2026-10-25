// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAjoScore} from "./interfaces/IAjoScore.sol";

/// @title Circle
/// @notice One rotating savings circle (ajo / esusu / jam'iya).
///
///  Lifecycle
///  1. Open:   members `join()`, each locking one round's contribution as collateral.
///             When the last seat fills, the circle starts automatically.
///  2. Active: there are as many rounds as members. Each round every member
///             `contribute()`s before the deadline. Members who have not been paid yet
///             may `bid()` the discount they will give up to take this round's pot.
///             After the deadline anyone calls `closeRound()`:
///               - each member who missed is slashed (collateral covers their payment),
///               - the highest bidder (or, with no bids, the first unpaid member in join
///                 order) receives pot - discount,
///               - the discount is split between every other member as claimable credit.
///  3. Completed: after the last round, collateral is returned, and the vault yield plus
///             any penalties are shared by members in good standing (no missed payment).
///
///  Idle money (contributions, collateral, unclaimed credit) sits in an ERC-4626 vault
///  when one is set, so the pot earns yield between payouts.
contract Circle is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Active,
        Completed
    }

    struct Config {
        string name;
        IERC20 token;
        IERC4626 vault; // address(0) = hold funds directly, no yield
        IAjoScore score;
        address creator;
        uint256 contribution; // per member per round, token base units
        uint256 maxMembers; // also the number of rounds
        uint256 roundDuration; // seconds each round stays open for payments and bids
        uint256 maxDiscountBps; // cap on a bid, as basis points of the full pot
    }

    struct Member {
        bool joined;
        bool paidOut;
        uint32 onTime;
        uint32 missed;
        uint256 collateral;
        uint256 debt; // unpaid contributions collateral could not cover
    }

    uint256 public constant MIN_MEMBERS = 2;
    uint256 public constant MAX_MEMBERS = 20;
    uint256 public constant MAX_DISCOUNT_BPS = 5_000; // never more than half the pot
    uint256 public constant MIN_ROUND_DURATION = 60; // short rounds keep demos fast
    uint256 internal constant BPS = 10_000;

    // ---------------------------------------------------------------- config
    string public name;
    IERC20 public immutable token;
    IERC4626 public immutable vault;
    IAjoScore public immutable score;
    address public immutable factory;
    address public immutable creator;
    uint256 public immutable contribution;
    uint256 public immutable maxMembers;
    uint256 public immutable roundDuration;
    uint256 public immutable maxDiscountBps;

    // ---------------------------------------------------------------- state
    Status public status;
    address[] internal _memberList;
    mapping(address => Member) public members;

    uint256 public currentRound; // 1-based once Active
    uint256 public roundDeadline; // payments and bids accepted up to and including this time
    uint256 public roundPot; // contributions collected this round
    uint256 public highestBid; // discount offered by the current leader
    address public highestBidder;

    mapping(uint256 => mapping(address => bool)) public contributed;
    mapping(uint256 => address) public roundWinner;
    mapping(address => uint256) public claimable;

    uint256 public totalCollateral;
    uint256 public totalClaimable;
    uint256 public penaltyPool; // recovered debt + rounding dust, shared at the end

    // ---------------------------------------------------------------- events
    event Joined(address indexed member, uint256 collateral);
    event Left(address indexed member);
    event Started(uint256 startTime, uint256 firstDeadline);
    event Contributed(uint256 indexed round, address indexed member, uint256 amount);
    event BidPlaced(uint256 indexed round, address indexed bidder, uint256 discount);
    event Slashed(uint256 indexed round, address indexed member, uint256 covered, uint256 shortfall);
    event CollateralToppedUp(address indexed member, uint256 amount);
    event RoundClosed(uint256 indexed round, address indexed winner, uint256 payout, uint256 discount);
    event Claimed(address indexed member, uint256 amount);
    event Completed(uint256 yieldEarned, uint256 bonusPerMember);

    // ---------------------------------------------------------------- errors
    error InvalidConfig();
    error WrongStatus();
    error NotMember();
    error AlreadyMember();
    error AlreadyContributed();
    error MustContributeFirst();
    error AlreadyPaidOut();
    error BidTooLow();
    error BidTooHigh();
    error RoundStillOpen();
    error RoundOver();
    error NothingToClaim();
    error CollateralFull();

    constructor(Config memory c) {
        if (
            c.maxMembers < MIN_MEMBERS || c.maxMembers > MAX_MEMBERS || c.contribution == 0
                || c.roundDuration < MIN_ROUND_DURATION || c.maxDiscountBps > MAX_DISCOUNT_BPS
                || address(c.token) == address(0) || address(c.score) == address(0)
        ) revert InvalidConfig();
        if (address(c.vault) != address(0) && c.vault.asset() != address(c.token)) revert InvalidConfig();

        name = c.name;
        token = c.token;
        vault = c.vault;
        score = c.score;
        factory = msg.sender;
        creator = c.creator;
        contribution = c.contribution;
        maxMembers = c.maxMembers;
        roundDuration = c.roundDuration;
        maxDiscountBps = c.maxDiscountBps;

        if (address(c.vault) != address(0)) c.token.forceApprove(address(c.vault), type(uint256).max);
    }

    // =============================================================== Open phase

    /// @notice Take a seat by locking one round's contribution as collateral.
    function join() external nonReentrant {
        if (status != Status.Open) revert WrongStatus();
        Member storage m = members[msg.sender];
        if (m.joined) revert AlreadyMember();

        m.joined = true;
        m.collateral = contribution;
        totalCollateral += contribution;
        _memberList.push(msg.sender);
        _pullIn(msg.sender, contribution);
        emit Joined(msg.sender, contribution);

        if (_memberList.length == maxMembers) {
            status = Status.Active;
            currentRound = 1;
            roundDeadline = block.timestamp + roundDuration;
            emit Started(block.timestamp, roundDeadline);
        }
    }

    /// @notice Leave before the circle starts and get the collateral back.
    function leave() external nonReentrant {
        if (status != Status.Open) revert WrongStatus();
        Member storage m = members[msg.sender];
        if (!m.joined) revert NotMember();

        uint256 refund = m.collateral;
        totalCollateral -= refund;
        delete members[msg.sender];

        // keep join order intact (it decides the no-bid fallback)
        uint256 n = _memberList.length;
        for (uint256 i; i < n; ++i) {
            if (_memberList[i] == msg.sender) {
                for (uint256 j = i; j + 1 < n; ++j) {
                    _memberList[j] = _memberList[j + 1];
                }
                _memberList.pop();
                break;
            }
        }
        _pushOut(msg.sender, refund);
        emit Left(msg.sender);
    }

    // =============================================================== Active phase

    /// @notice Pay this round's contribution. On-time payments build your AjoScore.
    function contribute() external nonReentrant {
        _requireActiveMember();
        if (block.timestamp > roundDeadline) revert RoundOver();
        uint256 r = currentRound;
        if (contributed[r][msg.sender]) revert AlreadyContributed();

        contributed[r][msg.sender] = true;
        members[msg.sender].onTime += 1;
        roundPot += contribution;
        _pullIn(msg.sender, contribution);
        score.recordPayment(msg.sender, contribution);
        emit Contributed(r, msg.sender, contribution);
    }

    /// @notice Offer `discount` (token units) to take this round's pot early.
    ///         The highest discount wins; it is shared by every other member.
    function bid(uint256 discount) external {
        _requireActiveMember();
        if (block.timestamp > roundDeadline) revert RoundOver();
        Member storage m = members[msg.sender];
        if (m.paidOut) revert AlreadyPaidOut();
        if (!contributed[currentRound][msg.sender]) revert MustContributeFirst();
        if (discount <= highestBid) revert BidTooLow();
        if (discount > maxDiscount()) revert BidTooHigh();

        highestBid = discount;
        highestBidder = msg.sender;
        emit BidPlaced(currentRound, msg.sender, discount);
    }

    /// @notice Re-lock collateral after it was used to cover a missed payment.
    function topUpCollateral() external nonReentrant {
        _requireActiveMember();
        Member storage m = members[msg.sender];
        if (m.collateral >= contribution) revert CollateralFull();
        uint256 amount = contribution - m.collateral;
        m.collateral = contribution;
        totalCollateral += amount;
        _pullIn(msg.sender, amount);
        emit CollateralToppedUp(msg.sender, amount);
    }

    /// @notice After the deadline, anyone can settle the round: slash missed payments,
    ///         pay the winner, share the discount, and open the next round.
    function closeRound() external nonReentrant {
        if (status != Status.Active) revert WrongStatus();
        if (block.timestamp <= roundDeadline) revert RoundStillOpen();
        uint256 r = currentRound;
        uint256 n = _memberList.length;

        // 1. slash everyone who missed this round
        for (uint256 i; i < n; ++i) {
            address a = _memberList[i];
            if (!contributed[r][a]) _slash(r, a);
        }

        // 2. pick the winner
        address winner = highestBidder;
        uint256 discount = highestBid;
        if (winner == address(0)) {
            winner = _fallbackWinner(r);
            discount = 0;
        }
        uint256 pot = roundPot;
        if (discount > pot) discount = pot;

        // 3. share the discount between everyone else
        if (discount > 0) {
            uint256 share = discount / (n - 1);
            for (uint256 i; i < n; ++i) {
                address a = _memberList[i];
                if (a != winner) claimable[a] += share;
            }
            totalClaimable += share * (n - 1);
            penaltyPool += discount - share * (n - 1); // rounding dust
        }

        // 4. winner's payout, minus any unpaid debt (which goes to the penalty pool)
        uint256 payout = pot - discount;
        Member storage w = members[winner];
        if (w.debt > 0) {
            uint256 take = w.debt < payout ? w.debt : payout;
            w.debt -= take;
            payout -= take;
            penaltyPool += take;
        }
        w.paidOut = true;
        roundWinner[r] = winner;

        // 5. reset round state
        roundPot = 0;
        highestBid = 0;
        highestBidder = address(0);
        emit RoundClosed(r, winner, payout, discount);

        _pushOut(winner, payout);

        if (r == maxMembers) {
            _finalize();
        } else {
            currentRound = r + 1;
            roundDeadline = block.timestamp + roundDuration;
        }
    }

    /// @notice Withdraw discount shares, returned collateral and end-of-circle bonus.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        uint256 sent = _pushOut(msg.sender, amount);
        emit Claimed(msg.sender, sent);
    }

    // =============================================================== views

    function memberCount() external view returns (uint256) {
        return _memberList.length;
    }

    function getMembers() external view returns (address[] memory) {
        return _memberList;
    }

    /// @notice Full pot when every member pays: contribution x members.
    function potSize() public view returns (uint256) {
        return contribution * maxMembers;
    }

    /// @notice Largest discount a bid may offer.
    function maxDiscount() public view returns (uint256) {
        return potSize() * maxDiscountBps / BPS;
    }

    function isGoodStanding(address a) public view returns (bool) {
        Member storage m = members[a];
        return m.joined && m.missed == 0 && m.debt == 0;
    }

    /// @notice Everything the circle holds right now, including vault yield.
    function totalAssets() public view returns (uint256) {
        if (address(vault) != address(0) && status != Status.Completed) {
            return vault.convertToAssets(vault.balanceOf(address(this)));
        }
        return token.balanceOf(address(this));
    }

    /// @notice Yield earned so far on top of what members are owed.
    function accruedYield() external view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 owed = totalCollateral + totalClaimable + penaltyPool + roundPot;
        return assets > owed ? assets - owed : 0;
    }

    // =============================================================== internals

    function _requireActiveMember() internal view {
        if (status != Status.Active) revert WrongStatus();
        if (!members[msg.sender].joined) revert NotMember();
    }

    function _slash(uint256 r, address a) internal {
        Member storage m = members[a];
        uint256 covered = m.collateral >= contribution ? contribution : m.collateral;
        uint256 shortfall = contribution - covered;
        m.collateral -= covered;
        totalCollateral -= covered;
        m.debt += shortfall;
        m.missed += 1;
        roundPot += covered;
        score.recordMissed(a);
        emit Slashed(r, a, covered, shortfall);
    }

    /// @dev First unpaid member in join order who paid this round, else first unpaid at all.
    function _fallbackWinner(uint256 r) internal view returns (address firstUnpaid) {
        uint256 n = _memberList.length;
        for (uint256 i; i < n; ++i) {
            address a = _memberList[i];
            if (members[a].paidOut) continue;
            if (contributed[r][a]) return a;
            if (firstUnpaid == address(0)) firstUnpaid = a;
        }
    }

    function _finalize() internal {
        status = Status.Completed;
        uint256 n = _memberList.length;

        // pull everything out of the vault; the circle holds plain tokens from here on
        if (address(vault) != address(0)) {
            uint256 shares = vault.balanceOf(address(this));
            if (shares > 0) vault.redeem(shares, address(this), address(this));
        }

        // return collateral, recovering any remaining debt from it first
        uint256 goodCount;
        for (uint256 i; i < n; ++i) {
            address a = _memberList[i];
            Member storage m = members[a];
            uint256 c = m.collateral;
            if (m.debt > 0) {
                uint256 take = m.debt < c ? m.debt : c;
                m.debt -= take;
                c -= take;
                penaltyPool += take;
            }
            m.collateral = 0;
            if (c > 0) {
                claimable[a] += c;
                totalClaimable += c;
            }
            if (m.missed == 0 && m.debt == 0) goodCount++;
        }
        totalCollateral = 0;

        // yield = whatever the circle holds beyond what it owes
        uint256 balance = token.balanceOf(address(this));
        uint256 owed = totalClaimable + penaltyPool;
        uint256 yieldEarned = balance > owed ? balance - owed : 0;
        uint256 bonusPool = yieldEarned + penaltyPool;

        uint256 bonusEach;
        if (bonusPool > 0) {
            bool everyone = goodCount == 0; // nobody clean: share with all
            uint256 recipients = everyone ? n : goodCount;
            bonusEach = bonusPool / recipients;
            for (uint256 i; i < n; ++i) {
                address a = _memberList[i];
                if (everyone || isGoodStanding(a)) claimable[a] += bonusEach;
            }
            totalClaimable += bonusEach * recipients;
            penaltyPool = bonusPool - bonusEach * recipients; // dust stays behind
        }

        for (uint256 i; i < n; ++i) {
            address a = _memberList[i];
            if (isGoodStanding(a)) score.recordCompletion(a);
        }
        emit Completed(yieldEarned, bonusEach);
    }

    function _pullIn(address from, uint256 amount) internal {
        token.safeTransferFrom(from, address(this), amount);
        if (address(vault) != address(0)) vault.deposit(amount, address(this));
    }

    /// @dev Sends `amount` to `to`, from the vault while Active, from balance once Completed.
    ///      Caps at what is available so vault rounding can never brick a payout.
    function _pushOut(address to, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        if (address(vault) != address(0) && status != Status.Completed) {
            uint256 max = vault.maxWithdraw(address(this));
            if (amount > max) amount = max;
            vault.withdraw(amount, to, address(this));
        } else {
            uint256 bal = token.balanceOf(address(this));
            if (amount > bal) amount = bal;
            token.safeTransfer(to, amount);
        }
        return amount;
    }
}
