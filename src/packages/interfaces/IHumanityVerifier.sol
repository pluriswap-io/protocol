// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `register` humanity circuit (PROTOCOLO.md §E.3.15.9: public input `hn`).
///      Behind it: the real proof, or a mock for integration — a passing mock is not privacy.
interface IHumanityVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyHumanity(bytes calldata proof, bytes32 hn) external view returns (bool);
}
