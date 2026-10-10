// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IBundleVerifier
/// @notice One side of an activation bundle, proven once and read by all three modules
///         (PROTOCOLO.md §E.3.15.4, as-built 2026-09-23).
///
/// @dev The three per-module proofs of one side were always describing one deal, and overlapping
///      while they did it. `prepare_side` merges them; this is the surface the modules see.
///
///      The shape is deliberately two calls rather than one. A verifier that took the proof from
///      every module and cached the result would keep each module's code identical — but the proof
///      would ride in the calldata three times, and the calldata is the whole point (53,824 bytes
///      down to 19,200 for a two-sided activation). So the proof is submitted ONCE, and what the
///      modules pass around afterwards is the inputs, which they each need anyway.
///
///      What keeps the trust model intact: the ticket is keyed by the HASH OF THE INPUTS, so a
///      module can only be satisfied by a proof of exactly the values it is about to act on. Each
///      module then enforces its own statement out of those inputs — the passport that the subject
///      is the one it identifies, the reputation that the leaf, nullifier and cap are the ones it
///      will write, the vault that the lock and change note are the ones it will store. No module
///      trusts another; all three trust a verifier the parties named in their `packageId`.
///
///      Said plainly, because it is the cost of this design: the trust surface does not change in
///      kind — every module already trusts its own adapter — but it concentrates. One contract can
///      forge a bundle where before it took three. In exchange there is one contract to audit
///      instead of three, and the ticket lives in transient storage, so nothing survives the
///      transaction that created it.
interface IBundleVerifier {
    /// @notice The public inputs of `prepare_side`, in the circuit's declared order.
    /// @dev `decimals` is not here on purpose: it is a public input of the circuit, but the adapter
    ///      reads it from the served ERC-20 and requires the proof to have used that value — the
    ///      same amplification `PrepareAdmitVerifier` performs, and for the same reason (the tier
    ///      scale is `UNIT = 250 * 10^decimals`, so a proof scaled for another token's decimals
    ///      must not admit this deal).
    struct BundleInputs {
        bytes32 dealSubject;
        bytes32 dealId;
        address token;
        uint256 principal;
        bytes32 repRoot;
        bytes32 newLeaf;
        bytes32 nullRep;
        bytes32 pairTag;
        /// @dev Zero means a deal without bonds: the circuit masks its whole note half, and the
        ///      four fields below are zero with it.
        bytes32 lockCommit;
        uint256 lockAmount;
        bytes32 changeNote;
        bytes32 nullBond;
        bytes32 bondRoot;
        /// @dev The humanity registry the side's own nullifier is taken in, and the panel it proves it is not
        ///      on (zeros without a panel). The court checks both (Anexo R, 2026-09-29).
        bytes32 registryId;
        /// @dev What the account must remember about the deal — the counterparty's `S` and the pair secret —
        ///      under a pad only it can rebuild: how a counterparty tree comes back from `sk_id` and the chain.
        bytes32 hintS;
        bytes32 hintK;
        bytes32[3] arbiters;
        /// @dev The account's own flag (2026-10-01): a proof of humanity stands behind it. The reputation
        ///      reads it to decide whether the deal can CREDIT (both sides verified) and refuses a bond
        ///      without it; the circuit binds it to the leaf, so an open account cannot claim it.
        bool verified;
    }

    /// @notice The public inputs of `vouch`, in the circuit's declared order (Anexo R, 2026-09-29; the pool's
    ///         three, 2026-10-05).
    /// @dev The pool's side of a deal, stood in for by a human: some registered account formed `pairTag` with
    ///      the Provider's `S` for this deal, and its human is none of `arbiters`; it is the operator behind
    ///      `operatorTag` in the pool `poolId`, and `cpTag` names the Provider in that pool. No subject, no leaf, no
    ///      nullifier — the voucher earns nothing, so vouching spends nothing of its account.
    struct VouchInputs {
        bytes32 dealId;
        bytes32 repRoot;
        bytes32 pairTag;
        bytes32 registryId;
        bytes32[3] arbiters;
        /// @dev The voucher's own flag (2026-10-01): only a verified human's vouch lets the Provider's deal credit.
        bool verified;
        /// @dev The pool this vouch is the side of (Anexo R, 2026-10-05): its subject,
        ///      `keccak256(abi.encode("pluri:pool", pool))`. The adapter reduces it mod p, so the raw subject works.
        bytes32 poolId;
        /// @dev `Poseidon(sk_id, "operator", poolId)`: the operator commitment the deal's Controller registered in
        ///      the pool. Equal to the registered one means the human vouching IS the Controller.
        bytes32 operatorTag;
        /// @dev `Poseidon("pool-cp", S_provider, poolId)`: the Provider's stable name in this pool's public
        ///      counterparty memory — how the pool credits once per distinct Provider.
        bytes32 cpTag;
    }

    /// @notice Verifies one side's proof and leaves a ticket for this transaction.
    /// @dev MUST fail closed: a malformed proof, a failed deploy or any revert inside the generated
    ///      verifier reads as `false`, never as a revert-shaped pass. Idempotent within a
    ///      transaction: a second call with the same inputs is a cheap `true`.
    function verify(BundleInputs calldata inputs, bytes calldata proof) external returns (bool);

    /// @notice Was exactly this side proven in THIS transaction?
    /// @dev What the modules call. The ticket is transient: it never answers `true` in a later
    ///      transaction, so a bundle cannot be assembled across blocks out of stale permission.
    function wasProven(BundleInputs calldata inputs) external view returns (bool);

    /// @notice Verifies a vouch and leaves its own ticket for this transaction. Same contract as `verify`:
    ///         fail-closed, idempotent within the transaction.
    function verifyVouch(VouchInputs calldata inputs, bytes calldata proof) external returns (bool);

    /// @notice Was exactly this vouch proven in THIS transaction?
    function wasVouched(VouchInputs calldata inputs) external view returns (bool);
}
