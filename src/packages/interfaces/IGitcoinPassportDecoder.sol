// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Read surface of Human Passport's `GitcoinPassportDecoder` (passportxyz/eas-proxy).
///      Scores carry 4 decimals (20.0000 = 200_000). Both getters revert with `AttestationNotFound`
///      or `AttestationExpired` instead of returning zero, so callers must `try`.
interface IGitcoinPassportDecoder {
    error AttestationNotFound();
    error AttestationExpired(uint64 expirationTime);

    function getScore(address user) external view returns (uint256);
    function isHuman(address user) external view returns (bool);
    function threshold() external view returns (uint256);
    function maxScoreAge() external view returns (uint64);
}
