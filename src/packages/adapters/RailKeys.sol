// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PinnedAnchors} from "./PinnedAnchors.sol";
import {IPaymentVerifier} from "../interfaces/IPaymentVerifier.sol";

/// @title RailKeys
/// @notice Which keys count for a deal (PROTOCOLO.md §E.3.12.1, Anexo R 2026-09-24): the adapter's pinned
///         defaults, plus any key the deal's Holder approved for that deal. Every rail adapter inherits it.
///
/// @dev The principle: **whoever a false key would hurt is whoever may vouch for a key.** A false key
///      releases the Holder's crypto against a payment that never happened — it hurts the Holder and
///      nobody else. A missing key strands the Provider's real payment. So the Holder may EXTEND trust
///      for their own deal, and the design is built around two asymmetries:
///
///        * the Holder can extend, never restrict. There is no veto: a Holder able to switch off a genuine
///          pinned key could deny a real payment and take the principal home at the timeout;
///        * nobody else can produce the extension. It is an EIP-712 signature by the `holder` of the signed
///          terms, over (dealId, keyHash), under this adapter's domain — the Provider, the one a false key
///          would pay, cannot make it; nor can it be carried to another deal, another key, another rail.
///
///      What this buys: a rotation no longer needs a redeploy (the Holder's client approves the rail's live
///      key when the deal is signed, after checking it against the rail's DNS itself), and an unplanned
///      rotation mid-deal is rescuable (the Holder approves the new key). There is no registry, no steward,
///      no DAO verb, no tribunal: the only authority in the system is a party over its own risk (principio 14).
///
///      Why it is not drift of a live deal (EXT-10): the approval is a post-activation consent by the party
///      at risk, of the same family as `MutualCancel` and `CoSignedRelease` — it names the `dealId`, not
///      the terms. The module's side, what the kernel snapshotted, is unchanged.
///
///      A pool as Holder does not get the extension, on purpose: `Pool.isValidSignature` only validates the
///      digests `authorize` registered, so an approval fails closed. Letting the pool's Controller approve
///      keys would let a Controller and a Provider drain the pool with a false key — and the Controller must
///      never be able to redirect principal. Pool deals run on the pinned defaults, as before.
///
///      No nonce, no deadline, no revocation: an approval only ever widens one deal, it is idempotent, and
///      the deal it names ends.
abstract contract RailKeys is PinnedAnchors, EIP712 {
    bytes32 public constant KEY_APPROVAL_TYPEHASH = keccak256("KeyApproval(bytes32 dealId,bytes32 keyHash)");

    constructor(Anchor[] memory anchors_) PinnedAnchors(anchors_) EIP712("PluriSwap Rail Keys", "1") {}

    /// @notice What the Holder's wallet signs to let `keyHash` attest the payment of `dealId` on this rail.
    function keyApprovalDigest(bytes32 dealId, bytes32 keyHash) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(KEY_APPROVAL_TYPEHASH, dealId, keyHash)));
    }

    /// @dev Whether `keyHash` may attest this claim's payment, and the bounds the circuit must place the
    ///      payment in. The pinned defaults are consulted first and the approval never touches them: that is
    ///      the "cannot restrict" half. An approved key is bounded like any pinned one — from the deal's
    ///      activation, for at most `MAX_WINDOW`. Fail-closed: every failure is `ok == false`, never a revert.
    function _keyAllowed(IPaymentVerifier.PaymentClaim memory claim, bytes32 keyHash, bytes memory holderApproval)
        internal
        view
        returns (bool ok, uint64 lo, uint64 hi)
    {
        if (keyHash == bytes32(0)) return (false, 0, 0);
        (ok, lo, hi) = _window(keyHash, claim.notBefore);
        if (ok) return (ok, lo, hi);
        if (holderApproval.length == 0) return (false, 0, 0);
        if (!SignatureChecker.isValidSignatureNow(
                claim.holder, keyApprovalDigest(claim.dealId, keyHash), holderApproval
            )) {
            return (false, 0, 0);
        }
        lo = claim.notBefore;
        uint256 end = uint256(lo) + MAX_WINDOW;
        hi = end > type(uint64).max ? type(uint64).max : uint64(end);
        return (true, lo, hi);
    }
}
