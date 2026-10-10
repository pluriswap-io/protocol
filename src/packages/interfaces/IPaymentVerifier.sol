// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPaymentVerifier
/// @notice The rail's side of `PAYMENT_PROOF` (PROTOCOLO.md §E.3.12.1): one statement every rail proves,
///         whatever technology carries the evidence — zkEmail, zkTLS, a signed Open Finance response.
///
/// @dev The statement is small on purpose, and it is the whole of what the kernel's side knows:
///
///        a payment happened, at or after `notBefore`, that opens `fiatCommit` —
///        same rail, same currency, at least the amount, to the same payee (§E.3.13) —
///        and this proof is about `dealId`.
///
///      The module builds the claim from the escrow (the signed terms and the activation clock), never
///      from the caller, and asks the adapter whether the proof names exactly that claim. Everything
///      rail-specific lives behind this interface: the circuit, its public-input layout, the mod-p
///      reduction of `dealId` at the boundary, and the TRUST ANCHORS — the DKIM key, the notary key, the
///      bank's signing key. Which keys count is one policy for every rail, `RailKeys`: the adapter's pinned
///      defaults, plus any key the deal's Holder approved for that deal — never a registry, never an authority.
///
///      `paymentNullifier` is the circuit's public output: derived from the rail's own transaction id,
///      so two pieces of evidence about ONE payment (two notification mails, a mail and a statement)
///      name the same nullifier and settle at most one deal.
///
///      Fail-closed, like every adapter of this protocol: a malformed blob, a mismatch, a failed deploy
///      or any revert inside the generated verifier returns `ok == false` — never a revert-shaped pass.
interface IPaymentVerifier {
    struct PaymentClaim {
        bytes32 dealId; // raw kernel id; the adapter compares it reduced mod p
        bytes32 fiatCommit; // from the signed terms; the module has checked it is a field element
        uint64 notBefore; // the deal's activation time: a payment before the escrow existed is not for it
        address holder; // from the signed terms: the one party whose approval may extend the keys (RailKeys)
    }

    function verify(PaymentClaim calldata claim, bytes calldata proof)
        external
        view
        returns (bool ok, bytes32 paymentNullifier);

    /// @notice The last instant any of this rail's pinned DEFAULT keys can attest a payment (`PinnedAnchors`).
    /// @dev Past it, a deal still works — but only on a key its Holder approved (`RailKeys`). A conforming
    ///      client reads it to know whether the deal it is about to sign needs that approval (§E.3.12.1).
    function sunset() external view returns (uint64);
}
