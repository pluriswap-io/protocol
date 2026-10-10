// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Module-to-module read side of `PrivatePassport`. The kernel-side `IPassport` (identify)
///      is an F2 concern; nothing in the kernel knows about this contract.
interface IPrivatePassport {
    /// @notice Has this humanity nullifier already been burned by a registration?
    function humanitySpent(bytes32 hn) external view returns (bool);

    /// @notice The subject of an official pool (Anexo R, 2026-09-29: a pool has reputation as a pool), or zero
    ///         for any other address.
    function poolSubjectOf(address wallet) external view returns (bytes32);
}
