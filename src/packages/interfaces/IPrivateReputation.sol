// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Module-to-module read side of `PrivateReputation`: the vault's reabsorb gating. The
///      kernel-side `IReputation` (admit / notifyTerminal / invoices) is an F2 concern; nothing in
///      the kernel knows about this contract.
interface IPrivateReputation {
    /// @notice Has the terminal delta of this deal subject already been applied to the account?
    ///         The lock of that deal only returns to its owner's notes after it has
    ///         (PROTOCOLO.md §E.3.15.6: the delta is atomic — not claiming means never releasing).
    function claimed(bytes32 dealSubject) external view returns (bool);
}
