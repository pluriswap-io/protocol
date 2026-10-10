// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the account circuits (PROTOCOLO.md §E.3.15.9): `register_account` in its two shapes — a
///      verified genesis bound to a burned `hn`, or an open one with no human behind it (2026-10-01) — and
///      `upgrade_account`, which verifies an open account in place.
///      Behind it: the real proof, or a mock for integration — a passing mock is not privacy.
interface IAccountVerifier {
    /// @notice A verified genesis: `leaf0` belongs to the human behind `hn`, and says so.
    /// @dev MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyAccount(bytes calldata proof, bytes32 hn, bytes32 leaf0) external view returns (bool);

    /// @notice An open genesis (2026-10-01): every counter zero and `verified = 0`, no human named.
    /// @dev MUST fail closed, like `verifyAccount`.
    function verifyOpenAccount(bytes calldata proof, bytes32 leaf0) external view returns (bool);

    /// @notice An open account verified in place (2026-10-01): the human behind `hn` owns the live open leaf
    ///         under `repRoot` whose version `nullRep` burns, and `newLeaf` is that leaf flagged — every stat
    ///         carried over, the version bumped.
    /// @dev MUST fail closed, like `verifyAccount`.
    function verifyUpgrade(bytes calldata proof, bytes32 hn, bytes32 repRoot, bytes32 nullRep, bytes32 newLeaf)
        external
        view
        returns (bool);
}
