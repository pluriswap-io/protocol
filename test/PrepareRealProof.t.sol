// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {RegistryHumanityVerifier} from "../src/packages/adapters/RegistryHumanityVerifier.sol";
import {RegistryAccountVerifier} from "../src/packages/adapters/RegistryAccountVerifier.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title One activation side with real proofs (PROTOCOLO.md §E.3.15.4, §E.3.15.9; Anexo R, 2026-09-29)
/// @dev The activation edge behind the REAL ultra_honk verifiers: register (V1's real proofs) puts the
///      genesis leaf into the account tree, then the side's committed `prepare_side` proof travels as
///      the kernel's opaque package data — `identify` verifies it and `admit` consumes it — and the
///      adapter-deployed Honk contract verifies it on-chain. The admission proof computes the §E.3.14.7 tier
///      IN-CIRCUIT (T1 here: a fresh account, 100 units into flight of a 6-dec token, base
///      cap 250); the adapter's amplifications — the served token's own decimals and the
///      zero lockCommit of the vault-less V2 — are what the negatives pin.
///
///      This is the second interface pair (IPreparePassportVerifier, IPrepareAdmitVerifier)
///      whose mock is gone. The claim side (IClaimVerifier) and the vault side remain mocks
///      until V3, and are marked as such.
contract PrepareRealProofTest is Test {
    /// @dev The §E.3.14.7 pair tag. With a mock verifier nothing checks its VALUE — what these tests
    ///      exercise is that both sides of one activation carry the SAME one, which is what the module
    ///      compares. The real value is pinned by the fixture tests and by the circuit itself.
    /// @dev The REAL pair tag of the pinned sample: this suite runs against committed proofs, so the
    ///      value has to be the one the circuit committed to.
    function pairTag() internal view returns (bytes32) {
        return bytes32(vm.parseJsonUint(vectors, ".prepare.pair_tag"));
    }

    /// @dev A fresh deal id / counterparty per call: these tests predate the 2026-09-23 rule that credit
    ///      is once per counterparty, and they all mean "another deal with somebody new". The ones that
    ///      mean "the same somebody again" say so by passing a fixed tag.
    uint256 private _tagNonce;

    function _dealTag() internal returns (bytes32) {
        return keccak256(abi.encode("deal", ++_tagNonce));
    }

    function _cpTag() internal returns (bytes32) {
        return keccak256(abi.encode("counterparty", ++_tagNonce));
    }
    address internal constant FEE_TO = address(0xFEE);
    uint256 internal constant WALLET_KEY = 0xA11CE;
    /// @dev The committed side is the bonded shape, so it is admitted into a deal that carries a vault:
    ///      a bonded proof in a vault-less deal would buy the higher cap with a lock nobody reserves.
    ///      The vault itself is absent from this suite; the reputation only needs to know its address.
    address internal constant VAULT = address(0xB0D5);

    string internal vectors;
    string internal proofHumanity;
    string internal proofAccount;
    string internal proofSide;

    PassportDecoderMock internal decoder;
    HumanityRegistry internal registry;
    RegistryHumanityVerifier internal humanityVerifier;
    RegistryAccountVerifier internal accountVerifier;
    BundleVerifier internal bundle;
    address internal anchor;
    address internal wallet;

    PoseidonTree internal accountTree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;

    bytes32 internal hsk;
    bytes32 internal hn;
    bytes32 internal leaf0;
    bytes32 internal dealId;
    bytes32 internal dealSubject;
    bytes32 internal repRoot;
    bytes32 internal newLeaf;
    bytes32 internal nullRep;
    address internal token;
    uint256 internal principal;
    uint256 internal deadline;

    function setUp() public {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        // forge's chain starts at timestamp 1: warp to a realistic clock so deadlines
        // carry meaning (the V1 lesson).
        vm.warp(1_700_000_000);
        deadline = block.timestamp + 2 hours;

        vectors = vm.readFile("test/fixtures/vectors.json");
        proofHumanity = vm.readFile("test/fixtures/proofs/register_humanity.json");
        proofAccount = vm.readFile("test/fixtures/proofs/register_account.json");
        proofSide = vm.readFile("test/fixtures/proofs/prepare_side.json");

        hsk = bytes32(vm.parseJsonUint(vectors, ".registry.hsk"));
        hn = bytes32(vm.parseJsonUint(vectors, ".registry.sample_hn"));
        leaf0 = bytes32(vm.parseJsonUint(vectors, ".registry.sample_leaf0"));
        dealId = bytes32(vm.parseJsonUint(vectors, ".prepare.deal_id"));
        dealSubject = bytes32(vm.parseJsonUint(vectors, ".prepare.deal_subject"));
        repRoot = bytes32(vm.parseJsonUint(vectors, ".prepare.root"));
        newLeaf = bytes32(vm.parseJsonUint(vectors, ".prepare.new_leaf"));
        nullRep = bytes32(vm.parseJsonUint(vectors, ".prepare.null_rep"));
        token = address(uint160(vm.parseJsonUint(vectors, ".prepare.token")));
        principal = vm.parseJsonUint(vectors, ".prepare.principal");

        // The pinned sample token is a synthetic address; the adapter's decimals
        // amplification reads `decimals()` on it, so a minimal 6-decimals oracle is etched
        // there (the proof's decimals pub is 6). A fresh address has no code: the read
        // fails closed, exactly like a token without the view.
        vm.etch(token, hex"600660005260206000f3"); // mstore(0, 6); return(0, 32)

        decoder = new PassportDecoderMock(200_000, 1 days);
        anchor = makeAddr("anchor");
        decoder.setScore(anchor, 200_000, uint64(block.timestamp + 30 days));
        registry = new HumanityRegistry(decoder, 0, bytes32(vm.parseJsonUint(vectors, ".registry.registry_id")));

        bytes32 commitment = registry.identityCommitmentOf(hsk);
        vm.prank(anchor);
        registry.enroll(commitment);

        humanityVerifier = new RegistryHumanityVerifier(
            registry, vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/register_humanity.json"), ".initcode")
        );
        accountVerifier = new RegistryAccountVerifier(
            registry,
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/register_account.json"), ".initcode"),
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/upgrade_account.json"), ".initcode")
        );
        bundle = new BundleVerifier(
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/prepare_side.json"), ".initcode"),
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/vouch.json"), ".initcode")
        );

        // Every remaining mock is pre-deployed BEFORE the prediction (the tree's owner is
        // the reputation): an inline `new Mock()` inside a constructor-argument list would
        // consume a CREATE nonce of this test contract and drift the predicted address.
        ClaimVerifierMock claimProof = new ClaimVerifierMock(); // V3 replaces this

        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        accountTree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        passport = new PrivatePassport(accountTree, humanityVerifier, bundle, address(0));
        reputation = new PrivateReputation(
            passport,
            accountTree,
            accountVerifier,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            VAULT,
            0,
            address(0)
        );
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");

        // Register the sample account with the V1 real-proof bundle: the account tree now
        // holds the genesis leaf0 both prepare proofs witness against.
        passport.register(proofHumanityBlob(), hn);
        reputation.register(proofAccountBlob(), hn, leaf0);
        assertEq(accountTree.nextIndex(), 1, "genesis leaf in");
        assertTrue(accountTree.isKnownRoot(repRoot), "the prepare root is the post-register root");

        wallet = vm.addr(WALLET_KEY);
    }

    function proofHumanityBlob() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofHumanity, ".proof_with_public_inputs");
    }

    function proofAccountBlob() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofAccount, ".proof_with_public_inputs");
    }

    /// The side as the merged circuit proved it (§E.3.15.4): the bonded shape, because the fixture is.
    /// The vault is absent from this suite, so nothing here reads `bondRoot` — what the passport and
    /// the reputation read is their own half, out of the same inputs.
    function side() internal view returns (IBundleVerifier.BundleInputs memory) {
        return IBundleVerifier.BundleInputs({
            dealSubject: dealSubject,
            dealId: dealId,
            token: token,
            principal: principal,
            repRoot: repRoot,
            newLeaf: newLeaf,
            nullRep: nullRep,
            pairTag: pairTag(),
            lockCommit: bytes32(vm.parseJsonUint(vectors, ".side.lock_commit")),
            lockAmount: vm.parseJsonUint(vectors, ".side.lock_amount"),
            changeNote: bytes32(vm.parseJsonUint(vectors, ".side.change_note")),
            nullBond: bytes32(vm.parseJsonUint(vectors, ".side.null_bond")),
            bondRoot: bytes32(vm.parseJsonUint(vectors, ".side.bond_root")),
            registryId: bytes32(vm.parseJsonUint(vectors, ".prepare.registry_id")),
            hintS: bytes32(vm.parseJsonUint(vectors, ".prepare.hint_s")),
            hintK: bytes32(vm.parseJsonUint(vectors, ".prepare.hint_k")),
            arbiters: [
                bytes32(vm.parseJsonUint(vectors, ".prepare.arbiters[0]")),
                bytes32(vm.parseJsonUint(vectors, ".prepare.arbiters[1]")),
                bytes32(vm.parseJsonUint(vectors, ".prepare.arbiters[2]"))
            ],
            verified: true
        });
    }

    function proofSideBlob() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofSide, ".proof_with_public_inputs");
    }

    /// @dev The side's package data as the kernel forwards it: the inputs and the proof, one blob.
    function _data(IBundleVerifier.BundleInputs memory s_, bytes memory proof) internal pure returns (bytes memory) {
        return abi.encode(s_, proof);
    }

    function _data() internal view returns (bytes memory) {
        return _data(side(), proofSideBlob());
    }

    // ---------------------------------------------------------------- the side, green path

    function test_side_admittedWithRealProofs() public {
        bytes memory data = _data();
        // The passport verifies the one proof of the side and answers the subject it names.
        assertEq(passport.identify(wallet, wallet, dealId, data), dealSubject);

        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.Admitted(wallet, dealSubject, token, principal);
        bytes32 subject = reputation.admit(wallet, dealId, token, principal, VAULT, data);
        assertEq(subject, dealSubject);

        // The version-0 nullifier burned. The leaf waits for the other side of the deal, which this
        // suite has no second real proof for: both leaves go into the tree together.
        assertTrue(accountTree.isSpent(nullRep));
        assertEq(accountTree.nextIndex(), 1, "a lone side inserts nothing");
    }

    function test_side_replayDiesOnTheNullifier() public {
        bytes memory data = _data();
        passport.identify(wallet, wallet, dealId, data);
        reputation.admit(wallet, dealId, token, principal, VAULT, data);
        // The proof itself is valid forever, but the version-0 nullifier is spent: the transition
        // cannot be replayed into a second activation.
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        reputation.admit(wallet, dealId, token, principal, VAULT, data);
    }

    // ---------------------------------------------------------------- adapter negatives

    function test_side_rejectsForeignRoot() public {
        // The modules gate the root against their own tree's window BEFORE asking the shared verifier
        // anything: an unknown root never reaches a verification.
        IBundleVerifier.BundleInputs memory foreignSide = side();
        foreignSide.repRoot = bytes32(uint256(keccak256("never-inserted")));
        bytes memory data = _data(foreignSide, proofSideBlob());
        vm.expectRevert(PrivatePassport.UnknownRoot.selector);
        passport.identify(wallet, wallet, dealId, data);
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.admit(wallet, dealId, token, principal, VAULT, data);
    }

    /// The proof names one deal: handed to another, it identifies nobody.
    function test_side_rejectsAnotherDeal() public {
        bytes memory data = _data();
        bytes32 other = keccak256("another deal");
        vm.expectRevert(PrivatePassport.DealMismatch.selector);
        passport.identify(wallet, wallet, other, data);
        vm.expectRevert(PrivateReputation.SideMismatch.selector);
        reputation.admit(wallet, other, token, principal, VAULT, data);
    }

    /// A root the tree knows, but a side nobody proved. The ticket is content-keyed, so an edited field is
    /// simply a side that was never verified — the real proof does not verify for it either.
    function test_side_rejectsASideThatWasNotProven() public {
        IBundleVerifier.BundleInputs memory edited = side();
        edited.newLeaf = keccak256("a leaf nobody proved");
        bytes memory data = _data(edited, proofSideBlob());
        vm.expectRevert(PrivatePassport.PassportProofFailed.selector);
        passport.identify(wallet, wallet, dealId, data);
        passport.identify(wallet, wallet, dealId, _data()); // the true side leaves a ticket...
        vm.expectRevert(PrivateReputation.AdmitProofFailed.selector);
        reputation.admit(wallet, dealId, token, principal, VAULT, data); // ...that the edited one cannot use
    }

    /// Without the passport's verification in the same transaction there is no ticket, and the
    /// reputation fails closed on its own.
    function test_side_withoutATicketFailsClosed() public {
        bytes memory data = _data();
        vm.expectRevert(PrivateReputation.AdmitProofFailed.selector);
        reputation.admit(wallet, dealId, token, principal, VAULT, data);
    }

    /// A bonded side cannot be admitted into a deal without the vault that would hold its lock.
    function test_side_bondedProofNeedsTheVault() public {
        bytes memory data = _data();
        passport.identify(wallet, wallet, dealId, data);
        vm.expectRevert(PrivateReputation.SideMismatch.selector);
        reputation.admit(wallet, dealId, token, principal, address(0), data);
    }

    /// Where one side's gas goes (§E.3.15.4). The verification is paid ONCE, inside the passport's
    /// `identify`; what the reputation pays afterwards is a ticket lookup, the nullifier and a transient
    /// park of its leaf (the insert happens on the second side, for both).
    function test_lever_sideDecomposition() public {
        bytes memory data = _data();

        uint256 before = gasleft();
        passport.identify(wallet, wallet, dealId, data);
        uint256 identify = before - gasleft();

        before = gasleft();
        reputation.admit(wallet, dealId, token, principal, VAULT, data);
        uint256 admit = before - gasleft();

        emit log_named_uint("passport.identify (the one verification of the side)", identify);
        emit log_named_uint("reputation.admit (ticket + spend + park)", admit);
        emit log_named_uint("one side, total", identify + admit);
    }

    /// @dev Solidity cannot slice memory bytes; the truncated-blob tests need copies.
    function _truncate(bytes memory b, uint256 n) internal pure returns (bytes memory) {
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
        return out;
    }
}
