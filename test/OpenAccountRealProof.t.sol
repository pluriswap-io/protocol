// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {RegistryHumanityVerifier} from "../src/packages/adapters/RegistryHumanityVerifier.sol";
import {RegistryAccountVerifier} from "../src/packages/adapters/RegistryAccountVerifier.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {ClaimVerifier} from "../src/packages/adapters/ClaimVerifier.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {CounterpartyBundle} from "./CounterpartyBundle.sol";

/// @title An account without a Passport, on real proofs (2026-10-01)
/// @dev The open account of the vectors (`open`) through its whole short life, every one of its proofs the
///      committed fixture verified by the adapter-deployed Honk contract: registered OPEN (`register_account`,
///      `verified = 0`), admitted to the sample deal against a verified counterparty (`prepare_side`, the open
///      shape: no bond), the deal closed Peaceful and claimed under `credit = 0` (`claim`, the record moves and
///      the credit does not) — and the tree lands exactly on the root its listing attestation witnesses. The
///      counterparty is the one side taken on trust (`CounterpartyBundle`), as in `VaultRealProof`.
contract OpenAccountRealProofTest is Test {
    bytes32 internal constant CP_SUBJECT = keccak256("pluri:test:counterparty-subject");
    address internal constant CP_WALLET = address(0xC0C0);
    address internal constant WALLET = address(0xA11CE);

    string internal vectors;
    RegistryAccountVerifier internal accountVerifier;
    BundleVerifier internal bundle;
    CounterpartyBundle internal cbundle;
    ClaimVerifier internal claimVerifier;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;
    HumanityRegistry internal registry;

    bytes32 internal dealId;
    address internal token;
    uint256 internal principal;
    bytes32 internal hn;

    function setUp() public {
        PoseidonSingletons.install();
        vm.warp(1_700_000_000); // the clock the claim's epoch was proven for
        vectors = vm.readFile("test/fixtures/vectors.json");
        dealId = bytes32(vm.parseJsonUint(vectors, ".prepare.deal_id"));
        token = address(uint160(vm.parseJsonUint(vectors, ".prepare.token")));
        principal = vm.parseJsonUint(vectors, ".prepare.principal");
        hn = bytes32(vm.parseJsonUint(vectors, ".registry.sample_hn"));
        // The adapter reads the served token's decimals: a real ERC-20 runtime at the synthetic address.
        vm.etch(token, type(TestToken).runtimeCode);

        PassportDecoderMock decoder = new PassportDecoderMock(200_000, 1 days);
        address anchor = makeAddr("anchor");
        decoder.setScore(anchor, 200_000, uint64(block.timestamp + 30 days));
        registry = new HumanityRegistry(decoder, 0, bytes32(vm.parseJsonUint(vectors, ".registry.registry_id")));
        bytes32 commitment = registry.identityCommitmentOf(bytes32(vm.parseJsonUint(vectors, ".registry.hsk")));
        vm.prank(anchor);
        registry.enroll(commitment);

        RegistryHumanityVerifier humanityVerifier =
            new RegistryHumanityVerifier(registry, _initcode("register_humanity"));
        accountVerifier =
            new RegistryAccountVerifier(registry, _initcode("register_account"), _initcode("upgrade_account"));
        bundle = new BundleVerifier(_initcode("prepare_side"), _initcode("vouch"));
        claimVerifier = new ClaimVerifier(_initcode("claim"));
        cbundle = new CounterpartyBundle(bundle);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predicted);
        passport = new PrivatePassport(tree, humanityVerifier, cbundle, address(0));
        reputation = new PrivateReputation(
            passport,
            tree,
            accountVerifier,
            cbundle,
            claimVerifier,
            address(0xFEE),
            0,
            0,
            0,
            0,
            address(this),
            address(0),
            0,
            address(0)
        );
        assertEq(address(reputation), predicted, "predicted tree owner drifted");
    }

    // ---------------------------------------------------------------- fixtures

    function _initcode(string memory circuit) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(string.concat("test/fixtures/verifiers/", circuit, ".json")), ".initcode");
    }

    function _proof(string memory name) internal view returns (bytes memory) {
        return vm.parseJsonBytes(
            vm.readFile(string.concat("test/fixtures/proofs/", name, ".json")), ".proof_with_public_inputs"
        );
    }

    function _b(string memory path) internal view returns (bytes32) {
        return bytes32(vm.parseJsonUint(vectors, path));
    }

    /// The open side as `prepare_side_open` proved it: the sample deal, no bond, `verified = false`.
    function _openSide() internal view returns (IBundleVerifier.BundleInputs memory i_) {
        i_.dealSubject = _b(".open.deal_subject");
        i_.dealId = dealId;
        i_.token = token;
        i_.principal = principal;
        i_.repRoot = _b(".open.root");
        i_.newLeaf = _b(".open.new_leaf");
        i_.nullRep = _b(".open.null_rep");
        i_.pairTag = _b(".open.pair_tag");
        i_.registryId = _b(".prepare.registry_id");
        i_.hintS = _b(".open.hint_s");
        i_.hintK = _b(".open.hint_k");
        i_.arbiters = [_b(".prepare.arbiters[0]"), _b(".prepare.arbiters[1]"), _b(".prepare.arbiters[2]")];
        i_.verified = false;
    }

    /// The verified counterparty, trusted: the leaf the vectors put next to the open side's in the batch.
    function _counterparty() internal view returns (IBundleVerifier.BundleInputs memory i_) {
        i_ = _openSide();
        i_.dealSubject = CP_SUBJECT;
        i_.newLeaf = _b(".side.counterparty_leaf");
        i_.nullRep = keccak256("pluri:test:counterparty-null-rep");
        i_.verified = true;
    }

    function _register() internal {
        reputation.registerOpen(_proof("register_account_open"), _b(".open.leaf0"));
        assertEq(tree.root(), _b(".open.root"), "the open sample's tree");
    }

    function _activate() internal {
        bytes memory data = abi.encode(_openSide(), _proof("prepare_side_open"));
        bytes memory cp = abi.encode(_counterparty(), bytes(""));
        cbundle.trust(_counterparty());
        assertEq(
            passport.identify(WALLET, WALLET, dealId, data), _b(".open.deal_subject"), "the real open proof identifies"
        );
        assertEq(passport.identify(CP_WALLET, CP_WALLET, dealId, cp), CP_SUBJECT);
        reputation.admit(WALLET, dealId, token, principal, address(0), data);
        reputation.admit(CP_WALLET, dealId, token, principal, address(0), cp);
        assertEq(tree.root(), _b(".open.claim_root"), "the activation's batch is the claim's witness root");
    }

    // ---------------------------------------------------------------- the life of an open account

    function test_theOpenAccount_tradesRecordsAndIsNeverCredited() public {
        _register();
        _activate();
        assertFalse(reputation.creditable(dealId), "an open side: the deal does not credit");

        reputation.notifyTerminal(_b(".open.deal_subject"), CP_SUBJECT, token, principal, IReputation.Close.Peaceful);
        reputation.claim(
            dealId,
            _b(".open.deal_subject"),
            _b(".open.claim_new_leaf"),
            _b(".open.claim_null_rep"),
            _b(".open.claim_root"),
            _proof("claim_open")
        );
        assertTrue(reputation.claimed(_b(".open.deal_subject")));
        // The record moved and the credit did not — the circuit's arithmetic — and the leaf that says so is the
        // very one the open listing attests: the tree now has the root `attest_base` witnesses for it.
        assertEq(tree.root(), _b(".open.attest_root"), "the open listing's root");
    }

    /// The word the module passes is part of what the claim proof binds: the same proof cannot ride a deal that
    /// credits, and the credited sample's proof cannot ride this one.
    function test_theClaimProof_bindsTheCreditWord() public view {
        bytes memory blob = _proof("claim_open");
        uint256 epoch = block.timestamp / 1 days;
        assertTrue(
            claimVerifier.verifyClaim(
                dealId,
                _b(".open.deal_subject"),
                _b(".open.claim_new_leaf"),
                _b(".open.claim_null_rep"),
                IReputation.Close.Peaceful,
                token,
                principal,
                _b(".open.claim_root"),
                _b(".open.pair_tag"),
                epoch,
                false,
                blob
            )
        );
        assertFalse(
            claimVerifier.verifyClaim(
                dealId,
                _b(".open.deal_subject"),
                _b(".open.claim_new_leaf"),
                _b(".open.claim_null_rep"),
                IReputation.Close.Peaceful,
                token,
                principal,
                _b(".open.claim_root"),
                _b(".open.pair_tag"),
                epoch,
                true,
                blob
            ),
            "credit = true is not what this proof says"
        );
        assertFalse(
            claimVerifier.verifyClaim(
                dealId,
                _b(".claim.deal_subject"),
                _b(".claim.new_leaf"),
                _b(".claim.null_rep"),
                IReputation.Close.Peaceful,
                token,
                principal,
                _b(".claim.root"),
                _b(".claim.pair_tag"),
                epoch,
                false,
                _proof("claim")
            ),
            "the credited sample cannot be claimed as uncreditable"
        );
    }

    /// The flag is part of the side's statement: the open proof does not pass as verified, nor the verified
    /// sample's proof as open.
    function test_theSideProof_bindsTheFlag() public {
        _register();
        IBundleVerifier.BundleInputs memory i_ = _openSide();
        assertTrue(bundle.verify(i_, _proof("prepare_side_open")));
        i_.verified = true;
        assertFalse(bundle.verify(i_, _proof("prepare_side_open")), "an open side cannot pass as verified");
        bytes memory data = abi.encode(i_, _proof("prepare_side_open"));
        vm.expectRevert(PrivatePassport.PassportProofFailed.selector);
        passport.identify(WALLET, WALLET, dealId, data);
    }

    /// The upgrade is a transition of the CURRENT version: once the activation spent the open genesis, the
    /// genesis upgrade cannot be replayed — the account verifies the leaf it has now.
    function test_aStaleVersion_cannotBeUpgraded() public {
        _register();
        _activate();
        PrivatePassport(address(passport)).register(_proof("register_humanity"), hn);
        bytes32 openRoot = _b(".open.root");
        bytes32 nullRep = _b(".open.null_rep");
        bytes32 newLeaf = _b(".open.upgrade_new_leaf");
        bytes memory proof = _proof("upgrade_account");
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        reputation.upgrade(proof, hn, openRoot, nullRep, newLeaf);
    }

    /// The genesis upgrade on real proofs, against the same open tree the side proves under.
    function test_theOpenGenesis_upgradesInPlace() public {
        _register();
        PrivatePassport(address(passport)).register(_proof("register_humanity"), hn);
        reputation.upgrade(
            _proof("upgrade_account"), hn, _b(".open.root"), _b(".open.null_rep"), _b(".open.upgrade_new_leaf")
        );
        assertTrue(reputation.registeredHn(hn));
        // The open activation proof is of the version the upgrade just spent: it cannot activate any more.
        bytes memory data = abi.encode(_openSide(), _proof("prepare_side_open"));
        passport.identify(WALLET, WALLET, dealId, data);
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        reputation.admit(WALLET, dealId, token, principal, address(0), data);
    }
}
