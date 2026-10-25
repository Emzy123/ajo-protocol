// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAjoScore} from "./interfaces/IAjoScore.sol";

/// @title AjoScore
/// @notice A non-transferable, onchain savings reputation. Only Circles created by the
///         CircleFactory can write to it; anyone (a lender, another dApp) can read it.
///         There is no transfer function: a score is bound to the address that earned it.
contract AjoScore is IAjoScore, Ownable {
    struct Record {
        uint32 onTimePayments;
        uint32 missedPayments;
        uint32 circlesCompleted;
        uint128 totalContributed; // in token base units (USDC = 6 decimals)
    }

    uint256 public constant BASE_SCORE = 500;
    uint256 public constant MAX_SCORE = 1000;
    uint256 public constant ON_TIME_POINTS = 10;
    uint256 public constant COMPLETION_POINTS = 50;
    uint256 public constant MISS_PENALTY = 100;

    address public factory;
    mapping(address => bool) public isCircle;
    mapping(address => Record) internal _records;

    event FactorySet(address indexed factory);
    event CircleRegistered(address indexed circle);
    event PaymentRecorded(address indexed member, address indexed circle, uint256 amount);
    event MissRecorded(address indexed member, address indexed circle);
    event CompletionRecorded(address indexed member, address indexed circle);

    error NotFactory();
    error NotCircle();
    error FactoryAlreadySet();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyCircle() {
        if (!isCircle[msg.sender]) revert NotCircle();
        _;
    }

    /// @notice One-time wiring of the factory that is allowed to register circles.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function registerCircle(address circle) external {
        if (msg.sender != factory) revert NotFactory();
        isCircle[circle] = true;
        emit CircleRegistered(circle);
    }

    function recordPayment(address member, uint256 amount) external onlyCircle {
        Record storage r = _records[member];
        r.onTimePayments += 1;
        r.totalContributed += uint128(amount);
        emit PaymentRecorded(member, msg.sender, amount);
    }

    function recordMissed(address member) external onlyCircle {
        _records[member].missedPayments += 1;
        emit MissRecorded(member, msg.sender);
    }

    function recordCompletion(address member) external onlyCircle {
        _records[member].circlesCompleted += 1;
        emit CompletionRecorded(member, msg.sender);
    }

    // ---------------------------------------------------------------- reads

    function recordOf(address member) external view returns (Record memory) {
        return _records[member];
    }

    function hasHistory(address member) public view returns (bool) {
        Record memory r = _records[member];
        return r.onTimePayments > 0 || r.missedPayments > 0;
    }

    /// @notice 0 = no history. Otherwise 500 base, +10 per on-time payment,
    ///         +50 per completed circle, -100 per missed payment, clamped to 0..1000.
    function scoreOf(address member) external view returns (uint256) {
        if (!hasHistory(member)) return 0;
        Record memory r = _records[member];
        uint256 plus =
            BASE_SCORE + uint256(r.onTimePayments) * ON_TIME_POINTS + uint256(r.circlesCompleted) * COMPLETION_POINTS;
        uint256 minus = uint256(r.missedPayments) * MISS_PENALTY;
        if (minus >= plus) return 0;
        uint256 s = plus - minus;
        return s > MAX_SCORE ? MAX_SCORE : s;
    }
}
