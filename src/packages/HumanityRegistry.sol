// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IGitcoinPassportDecoder} from "./interfaces/IGitcoinPassportDecoder.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "./PoseidonTree.sol";
import {PrivacyCommitments} from "./libraries/PrivacyCommitments.sol";

/// @title HumanityRegistry
/// @notice Semaphore-style enrollment of Passport-scored anchors into a Poseidon tree — the
///         declared-trust humanity oracle behind the `register` circuits (PROTOCOLO.md
///         §E.3.15.3 "Registro", §E.3.15.9 V1 as-built).
/// @dev The registry checks the Passport decoder ON-CHAIN AT ENROLL — the one place the
///      anchor is necessarily public: the enrolling wallet IS the anchor, and `enroll` is the
///      decoder's score gate. What the tree stores is NOT the anchor but the identity
///      commitment `PoseidonT2(hsk)` of a per-human secret `hsk` the registry never learns,
///      and one anchor enrolls exactly one commitment (one human, one identity, forever).
///      The `register_humanity` circuit then proves membership of that commitment and derives
///      `hn = PoseidonT3(hsk, registryId)` — deriving hn from the anchor would be enumerable
///      by any decoder observer (the anchor is public here); deriving it from the secret is
///      not: the tree's leaves are one-way in hsk, and hn cannot be recomputed from them.
///
///      `registryId` is a deployment domain (constructor arg, immutable): hn is nullified
///      per registry, so a proof naming a foreign domain fails closed at the adapter. The
///      canonical domain of this protocol is the one pinned in `test/fixtures/vectors.json`
///      (`.registry.registry_id`), the same constant the circuit vectors use.
contract HumanityRegistry {
    /// @dev Enrollment tree depth (1M anchors), §E.3.15.9. The `register_humanity` witness is
    ///      exactly this long.
    uint8 public constant TREE_DEPTH = 20;

    IGitcoinPassportDecoder public immutable decoder;
    /// @dev Same policy shape as `HumanPassport`: `minScore == 0` defers to the decoder's own
    ///      `isHuman`; `minScore > 0` pins a threshold here (4 decimals).
    uint256 public immutable minScore;
    bytes32 public immutable registryId;
    PoseidonTree public immutable tree;

    mapping(address anchor => bool enrolled) private _enrolled;

    event Enrolled(address indexed anchor, bytes32 indexed identityCommitment, uint256 index, bytes32 root);

    error ZeroDecoder();
    error ZeroRegistryId();
    error ZeroCommitment();
    error AnchorAlreadyEnrolled();
    error NotHuman();

    constructor(IGitcoinPassportDecoder decoder_, uint256 minScore_, bytes32 registryId_) {
        if (address(decoder_) == address(0)) revert ZeroDecoder();
        if (registryId_ == 0) revert ZeroRegistryId();
        decoder = decoder_;
        minScore = minScore_;
        registryId = registryId_;
        tree = new PoseidonTree(TREE_DEPTH, DEFAULT_ROOT_HISTORY, address(this));
    }

    /// @notice Enrolls one identity commitment for the calling anchor, gated by the Passport
    ///         decoder. The anchor reveals itself here and only here; from this point on,
    ///         everything on-chain is `hsk`-side: the commitment in the tree, and the proofs.
    function enroll(bytes32 identityCommitment) external {
        address anchor = msg.sender;
        if (_enrolled[anchor]) revert AnchorAlreadyEnrolled();
        if (identityCommitment == 0) revert ZeroCommitment();
        if (!isHuman(anchor)) revert NotHuman();
        _enrolled[anchor] = true;
        (uint256 index, bytes32 root) = tree.insert(identityCommitment);
        emit Enrolled(anchor, identityCommitment, index, root);
    }

    /// @notice Has an anchor already spent its one enrollment?
    function enrolled(address anchor) external view returns (bool) {
        return _enrolled[anchor];
    }

    /// @notice Humanity gate at enrollment. Never reverts; a decoder failure (no attestation,
    ///         expiry, pause) reads as `false` — enrollment fails closed, like `HumanPassport`.
    function isHuman(address anchor) public view returns (bool) {
        if (minScore == 0) {
            try decoder.isHuman(anchor) returns (bool ok) {
                return ok;
            } catch {
                return false;
            }
        }
        try decoder.getScore(anchor) returns (uint256 s) {
            return s >= minScore;
        } catch {
            return false;
        }
    }

    /// @notice Live root of the enrollment tree — the public input side of `register_humanity`.
    function root() external view returns (bytes32) {
        return tree.root();
    }

    /// @notice True while `root_` is in the enrollment tree's ring buffer — what the humanity
    ///         adapter checks against the proof's root public input.
    function isKnownRoot(bytes32 root_) external view returns (bool) {
        return tree.isKnownRoot(root_);
    }

    /// @notice The identity commitment of a secret, as the circuits compute it — for UIs and
    ///         tests (the enrollment side of the chain; the proof side lives in Noir).
    function identityCommitmentOf(bytes32 hsk) external view returns (bytes32) {
        return PrivacyCommitments.accountCommitment(hsk);
    }
}
