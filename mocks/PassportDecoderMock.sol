// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";

/// @dev Stand-in for Human Passport's `GitcoinPassportDecoder` where the real one is not deployed
///      (Arbitrum Sepolia, local). Same revert surface: no attestation and expiry revert, they do not return 0.
///      Writable by the deployer only so a test net never lets a wallet score itself.
contract PassportDecoderMock is IGitcoinPassportDecoder {
    error Unauthorized();
    error Paused();

    struct Cached {
        uint256 score;
        uint64 time;
        uint64 expirationTime;
    }

    address public immutable admin;
    uint256 public threshold;
    uint64 public maxScoreAge;
    bool public paused;
    mapping(address user => Cached) public cached;

    constructor(uint256 threshold_, uint64 maxScoreAge_) {
        admin = msg.sender;
        threshold = threshold_;
        maxScoreAge = maxScoreAge_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    function setScore(address user, uint256 score, uint64 expirationTime) external onlyAdmin {
        cached[user] = Cached({score: score, time: uint64(block.timestamp), expirationTime: expirationTime});
    }

    function clear(address user) external onlyAdmin {
        delete cached[user];
    }

    function setThreshold(uint256 t) external onlyAdmin {
        threshold = t;
    }

    function setPaused(bool p) external onlyAdmin {
        paused = p;
    }

    function getScore(address user) public view returns (uint256) {
        if (paused) revert Paused();
        Cached memory c = cached[user];
        if (c.time == 0) revert AttestationNotFound();
        uint64 exp = c.expirationTime == 0 ? c.time + maxScoreAge : c.expirationTime;
        if (block.timestamp >= exp) revert AttestationExpired(exp);
        return c.score;
    }

    function isHuman(address user) external view returns (bool) {
        return getScore(user) >= threshold;
    }
}
