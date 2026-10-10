// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `reabsorb` circuit (PROTOCOLO.md §E.3.15.6). `dealId`, `token`, `amount` and
///      `lockCommit` are read from the vault's own lock record — the caller does not supply them.
///      The proof says: "I know the account behind `dealSubject = Poseidon(sk_id, dealId)`; the
///      stored `lockCommit` opens to `(sk_id, dealId, amount, salt)`; and
///      `newNote = Poseidon(sk_id, token, kept, newSalt)`, with `1 <= kept <= amount`" — the whole lock, or
///      what a court left of it (Anexo R, 2026-10-05). There is no membership claim and no
///      root: the lock record is contract state, not a leaf, and the account's existence was
///      proven when the deal activated. Gated by `reputation.claimed(dealSubject)` on the contract
///      side: the lock only comes back after the terminal delta was applied to the account.
interface IReabsorbVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyReabsorb(
        bytes32 dealId,
        bytes32 dealSubject,
        address token,
        uint256 amount,
        uint256 kept,
        bytes32 lockCommit,
        bytes32 newNote,
        bytes32 nullBond,
        bytes calldata proof
    ) external view returns (bool);
}
