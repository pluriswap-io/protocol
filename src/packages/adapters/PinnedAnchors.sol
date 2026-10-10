// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PinnedAnchors
/// @notice The key rotation policy of `PAYMENT_PROOF` (PROTOCOLO.md §E.3.12.1, Anexo R 2026-09-24), as the
///         base every rail adapter inherits: the trust anchors — a DKIM key, a notary key, a bank's signing
///         key, identified by the hash the rail's circuit exposes — are fixed at deploy, each with a bounded
///         window, and nothing can change them afterwards.
///
/// @dev Why fixed, and not a registry. The adapter's address is inside the ZK `packageId`, so what is
///      pinned here is part of what the three parties signed. A registry that can ADD a key can forge a
///      proof for every live deal under that package — a drain with a signature on it; one that can REMOVE
///      a key can strand every honest Provider mid-deal — a kill switch. Neither survives II.
///
///      So a rotation is publication, not an edit: a new adapter pinning the new key, a new `PaymentProof`,
///      a new `packageId`. Anyone can deploy it (PERM-03). Deals already signed keep the package they signed
///      (EXT-10) and settle under it until its `sunset`; there is nothing to migrate.
///
///      The window does three jobs at once:
///        * the adapter hands the circuit [max(notBefore, validFrom), validUntil] and the circuit proves the
///          payment falls inside — so a key only counts for what it could have signed, and the payment
///          time is never published;
///        * overlapping windows let an adapter pin the current key AND a pre-published successor, which is
///          how a planned rotation crosses a live deal without stranding it;
///        * `MAX_WINDOW` bounds a leaked key with no governance at all: even a package nobody maintains
///          stops trusting a key after at most thirteen months.
///
///      These are the DEFAULTS: the keys that count with nobody doing anything. What they cannot cover — a
///      rotation nobody pinned, including one in the middle of a live deal — `RailKeys` covers with the
///      Holder's own approval, per deal. Adapters inherit `RailKeys`, not this contract directly.
abstract contract PinnedAnchors {
    struct Anchor {
        bytes32 keyHash; // what the rail's circuit exposes for the key that signed the evidence
        uint64 validFrom; // earliest payment this key may attest
        uint64 validUntil; // latest payment this key may attest
    }

    error NoAnchors();
    error TooManyAnchors();
    error BadAnchor();

    /// @notice The longest any key may be trusted. Thirteen months: a year of use plus a month of overlap
    ///         for the handover to a successor — and the same order as the web's own certificate ceiling.
    uint64 public constant MAX_WINDOW = 400 days;

    /// @notice A current key, its successor, and room for a rail that signs with several keys at once.
    uint256 public constant MAX_ANCHORS = 8;

    /// @notice The last instant any pinned key can attest a payment. After it, this package settles nothing.
    uint64 public immutable sunset;

    /// @dev Written once in the constructor; this contract has no function that writes it again.
    Anchor[] private _anchors;

    constructor(Anchor[] memory anchors_) {
        uint256 n = anchors_.length;
        if (n == 0) revert NoAnchors();
        if (n > MAX_ANCHORS) revert TooManyAnchors();
        uint64 last;
        for (uint256 i = 0; i < n; i++) {
            Anchor memory a = anchors_[i];
            if (a.keyHash == bytes32(0)) revert BadAnchor();
            if (a.validUntil <= a.validFrom) revert BadAnchor();
            if (a.validUntil - a.validFrom > MAX_WINDOW) revert BadAnchor();
            for (uint256 j = 0; j < i; j++) {
                if (anchors_[j].keyHash == a.keyHash) revert BadAnchor();
            }
            if (a.validUntil > last) last = a.validUntil;
            _anchors.push(a);
        }
        sunset = last;
    }

    /// @notice Every pinned anchor — what a client compares against the rail's live keys before signing.
    function anchors() external view returns (Anchor[] memory) {
        return _anchors;
    }

    /// @dev The bounds a proof under `keyHash` must place the payment in, for a deal activated at
    ///      `notBefore`. `ok == false` for a key nobody pinned, or one whose window closed before the deal
    ///      existed. Fail-closed: the adapter returns `ok == false` to the module, never reverts.
    function _window(bytes32 keyHash, uint64 notBefore) internal view returns (bool ok, uint64 lo, uint64 hi) {
        uint256 n = _anchors.length;
        for (uint256 i = 0; i < n; i++) {
            Anchor storage a = _anchors[i];
            if (a.keyHash != keyHash) continue;
            if (notBefore > a.validUntil) return (false, 0, 0);
            lo = notBefore > a.validFrom ? notBefore : a.validFrom;
            return (true, lo, a.validUntil);
        }
        return (false, 0, 0);
    }
}
