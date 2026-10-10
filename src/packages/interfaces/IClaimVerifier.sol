// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReputation} from "./IReputation.sol";

/// @dev Verifier of the `claim` circuit (PROTOCOLO.md §E.3.15.9: public inputs `dealId`, `dealSubject`,
///      `newLeaf`, `nullRep(v)`, `repRoot`, plus the delta values the contract reads from `pending`).
///      The proof says: "I know the account behind `dealSubject = Poseidon(sk_id, dealId)`; its current
///      leaf sits in a live tree; `newLeaf` is that leaf with the terminal delta (`kind`, `principal`,
///      `token`) applied — the atomic delta of PROTOCOLO.md §E.3.15.5 — and `nullRep(v)` is the current
///      version's nullifier". The delta arithmetic (including no negative `inFlight`) is proven
///      in-circuit; the contract only trusts the verifier's word and manages tree, nullifiers and flags.
interface IClaimVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyClaim(
        bytes32 dealId,
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        IReputation.Close kind,
        address token,
        uint256 principal,
        bytes32 repRoot,
        /// @dev The §E.3.14.7 anti-farming pair tag the two sides agreed on at activation, and the rate
        ///      epoch. Both come from the contract, never from the prover: the tag from the deal's own
        ///      record, the epoch from `block.timestamp` — a circuit has no clock and no memory of who
        ///      you traded with, so this is how both get in.
        bytes32 pairTag,
        uint256 epoch,
        /// @dev Whether the deal may CREDIT (2026-10-01): the module's own `creditable[dealId]` — both sides
        ///      verified when it activated. False still records the completed deal and applies every penalty.
        bool credit,
        bytes calldata proof
    ) external view returns (bool);
}
