// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IHumanityVerifier} from "./interfaces/IHumanityVerifier.sol";
import {IBundleVerifier} from "./interfaces/IBundleVerifier.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {IPoolOperators} from "./interfaces/IPoolOperators.sol";
import {PoseidonTree} from "./PoseidonTree.sol";
import {VouchData} from "./libraries/VouchData.sol";

/// @title PrivatePassport
/// @notice Humanity gate and deal-subject oracle of the private packages (PROTOCOLO.md §E.3.15.3–E.3.15.4).
/// @dev Two verbs, two proofs, no wallets read:
///      * `register` burns a humanity nullifier (`hn = Poseidon(anchor, registryId)`): one human
///        anchor, one account, forever. Two disjoint anchors are two accounts — the same sybil line
///        as the on-chain Passport adapters.
///      * `identify` is the kernel's, inside `Escrow.activate`: `data` carries the side's merged
///        `prepare_side` inputs and proof (Anexo R, 2026-09-29). It checks that the proof names this
///        deal and a root the tree still accepts, has the shared `BundleVerifier` verify it once —
///        leaving the transient ticket the reputation and the vault read a moment later — and answers
///        the `dealSubject` the proof names. There is no buffer and no `prepare`: a proof has nowhere to
///        execute outside an activation, and nothing of it survives one that fails.
///      There is no wallet consent signature either. It existed so a compositor could not hang A's
///      subject under B's wallet, but a side's proof is bound to a `dealId` the wallets signed, and only
///      the account owner can produce it — whoever hands it over for this deal is the one consenting.
///      A pool (Anexo R, 2026-09-29) has no `sk_id` and cannot prove humanity: an OFFICIAL pool — one the
///      pinned factory made — is identified by its address instead, with no account proof. Its reputation is
///      the pool's, public, kept by the reputation module, on the same ladder as anyone's (2026-10-05).
///      Each side is an account and an operator (Anexo R, 2026-10-05). For a person they are one, and the proof is
///      the account's own. For a pool the account is the pool and the operator its Controller, and the pool's side
///      MUST be the operator's vouch: verified (every operator of a pool is a human with a Passport), for THIS
///      pool, and by the human whose operator tag the pool registered for this Controller. `identify` verifies it
///      here, leaving the ticket the reputation and the court read, and answers the pool's subject. A pool's side
///      is never a person's account, and a vouch is never a person's side.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivatePassport is IPrivatePassport, IPassport {
    PoseidonTree public immutable accountTree;
    IHumanityVerifier public immutable humanityVerifier;
    /// @dev The shared verifier of §E.3.15.4: one proof per side, read by all three modules. Immutable,
    ///      and the module's address IS its `packageId`, so consenting to the package is consenting to
    ///      this verifier — exactly the relationship the per-module verifier had.
    IBundleVerifier public immutable bundleVerifier;
    /// @dev The factory whose pools this passport identifies without a proof; zero identifies none.
    address public immutable poolFactory;

    mapping(bytes32 => bool) public spentHumanity;

    event HumanityRegistered(bytes32 indexed hn);

    error ZeroAddress();
    error HumanAlreadySpent();
    error HumanityNotVerified();
    error UnknownRoot();
    error PassportProofFailed();
    error DealMismatch();
    /// @dev A vouch is a pool's side (Anexo R, 2026-09-29); a person proves their own account.
    error NotAPool();
    /// @dev A pool's side is its operator's vouch; a person's account never stands in as the pool.
    error PoolSideNotAVouch();
    /// @dev A pool acts through its operator (Anexo R, 2026-10-05): its side cannot be empty.
    error OperatorRequired();
    /// @dev The vouch names another pool.
    error PoolMismatch();
    /// @dev Every operator of a pool is a verified human.
    error OperatorNotVerified();
    /// @dev The human who vouched is not the one the pool registered for this Controller.
    error OperatorMismatch();

    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    constructor(
        PoseidonTree accountTree_,
        IHumanityVerifier humanityVerifier_,
        IBundleVerifier bundleVerifier_,
        address poolFactory_
    ) {
        if (
            address(accountTree_) == address(0) || address(humanityVerifier_) == address(0)
                || address(bundleVerifier_) == address(0)
        ) {
            revert ZeroAddress();
        }
        accountTree = accountTree_;
        humanityVerifier = humanityVerifier_;
        bundleVerifier = bundleVerifier_;
        poolFactory = poolFactory_;
    }

    // ------------------------------------------------------------------ register (F1)

    /// @notice Burns a humanity nullifier. Runs in the same bundle tx as
    ///         `PrivateReputation.register` with the same `hn`.
    function register(bytes calldata proof, bytes32 hn) external {
        if (spentHumanity[hn]) revert HumanAlreadySpent();
        if (!humanityVerifier.verifyHumanity(proof, hn)) revert HumanityNotVerified();
        spentHumanity[hn] = true;
        emit HumanityRegistered(hn);
    }

    /// @notice Read side for `PrivateReputation.register`: has this hn been proven before?
    function humanitySpent(bytes32 hn) external view returns (bool) {
        return spentHumanity[hn];
    }

    // ------------------------------------------------------------------ kernel edge (F2)

    /// @inheritdoc IPassport
    /// @dev `data` is `abi.encode(IBundleVerifier.BundleInputs, bytes proof)`. Anyone may call it: all it
    ///      can leave behind is the verifier's transient ticket, which dies with the transaction.
    function identify(address wallet, address operator, bytes32 dealId, bytes calldata data)
        external
        returns (bytes32 subject)
    {
        subject = poolSubjectOf(wallet);
        if (subject != bytes32(0)) {
            _operator(wallet, operator, subject, dealId, data);
            return subject;
        }
        if (data.length == 0) revert NoPassport();
        if (VouchData.isVouch(data)) revert NotAPool();
        (IBundleVerifier.BundleInputs memory inputs, bytes memory proof) =
            abi.decode(data, (IBundleVerifier.BundleInputs, bytes));
        if (inputs.dealId != dealId) revert DealMismatch();
        if (!accountTree.isKnownRoot(inputs.repRoot)) revert UnknownRoot();
        if (!bundleVerifier.verify(inputs, proof)) revert PassportProofFailed();
        return inputs.dealSubject;
    }

    /// @dev The pool's operator, proven: a vouch for this deal, under a root the tree accepts, verified once by the
    ///      shared verifier; for this pool; by a verified account; and by the human whose tag the pool registered for
    ///      the deal's Controller. The tag is read fail-closed: a pool that does not answer has no operator.
    function _operator(address pool, address operator, bytes32 subject, bytes32 dealId, bytes calldata data) internal {
        if (data.length == 0) revert OperatorRequired();
        if (!VouchData.isVouch(data)) revert PoolSideNotAVouch();
        (IBundleVerifier.VouchInputs memory v, bytes memory proof) = VouchData.decode(data);
        if (v.dealId != dealId) revert DealMismatch();
        if (uint256(v.poolId) % BN254_P != uint256(subject) % BN254_P) revert PoolMismatch();
        if (!v.verified) revert OperatorNotVerified();
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeCall(IPoolOperators.operatorTagOf, (operator)));
        if (!ok || ret.length < 32) revert OperatorMismatch();
        bytes32 tag = abi.decode(ret, (bytes32));
        if (tag == bytes32(0) || tag != v.operatorTag) revert OperatorMismatch();
        if (!accountTree.isKnownRoot(v.repRoot)) revert UnknownRoot();
        if (!bundleVerifier.verifyVouch(v, proof)) revert PassportProofFailed();
    }

    /// @inheritdoc IPrivatePassport
    function poolSubjectOf(address wallet) public view returns (bytes32) {
        if (poolFactory == address(0)) return bytes32(0);
        (bool ok, bytes memory ret) = poolFactory.staticcall(abi.encodeWithSignature("isOfficial(address)", wallet));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) return bytes32(0);
        return keccak256(abi.encode("pluri:pool", wallet));
    }

    /// @inheritdoc IPassport
    function packageId() external view returns (bytes32) {
        return PackageId.passport(address(this));
    }
}
