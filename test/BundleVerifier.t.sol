// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @title The shared bundle verifier, against the real proof
/// @dev One side of an activation is one `prepare_side` proof now (PROTOCOLO.md §E.3.15.4): its
///      passport, its admission and its bond split in a single statement, 19,200 bytes of calldata
///      for a two-sided deal instead of 53,824. This suite drives the adapter with the COMMITTED
///      proof — no mock anywhere — and pins the three things it promises: that it accepts exactly
///      the side that was proven, that it refuses everything else, and that the ticket it leaves is
///      content-keyed and transient.
contract BundleVerifierTest is Test {
    BundleVerifier internal bundle;
    TestToken internal token;
    string internal vectors;
    string internal proofJson;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/vectors.json");
        proofJson = vm.readFile("test/fixtures/proofs/prepare_side.json");
        bundle = new BundleVerifier(
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/prepare_side.json"), ".initcode"),
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/vouch.json"), ".initcode")
        );
        // The proof committed to the sample token's decimals, and the adapter reads them off the
        // SERVED contract: the token has to answer the same 6 the circuit was given.
        token = new TestToken();
        assertEq(token.decimals(), uint8(vm.parseJsonUint(vectors, ".prepare.decimals")), "sample decimals");
        // The sample's token id is a synthetic 20-byte value, so the deployed token stands in for it
        // at the address the proof names.
        vm.etch(_token(), address(token).code);
    }

    function _n(string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(vectors, path);
    }

    function _b(string memory path) internal view returns (bytes32) {
        return bytes32(_n(path));
    }

    function _token() internal view returns (address) {
        return address(uint160(_n(".prepare.token")));
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofJson, ".proof_with_public_inputs");
    }

    /// The side exactly as the circuit proved it.
    function _side() internal view returns (IBundleVerifier.BundleInputs memory) {
        return IBundleVerifier.BundleInputs({
            dealSubject: _b(".prepare.deal_subject"),
            dealId: _b(".prepare.deal_id"),
            token: _token(),
            principal: _n(".prepare.principal"),
            repRoot: _b(".prepare.root"),
            newLeaf: _b(".prepare.new_leaf"),
            nullRep: _b(".prepare.null_rep"),
            pairTag: _b(".prepare.pair_tag"),
            lockCommit: _b(".side.lock_commit"),
            lockAmount: _n(".side.lock_amount"),
            changeNote: _b(".side.change_note"),
            nullBond: _b(".side.null_bond"),
            bondRoot: _b(".side.bond_root"),
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

    function test_verify_theRealBundle() public {
        IBundleVerifier.BundleInputs memory side = _side();
        assertFalse(bundle.wasProven(side), "no ticket before the proof");
        assertTrue(bundle.verify(side, _proof()), "the committed proof verifies");
        assertTrue(bundle.wasProven(side), "and leaves its ticket");
    }

    /// The second call is the cheap path: the ticket answers, the Honk verifier is not touched. This
    /// is what makes the two-step shape affordable — the modules ask, they do not re-verify.
    function test_verify_isIdempotentWithinTheTransaction() public {
        IBundleVerifier.BundleInputs memory side = _side();
        bytes memory proof = _proof();
        uint256 before = gasleft();
        bundle.verify(side, proof);
        uint256 first = before - gasleft();
        before = gasleft();
        bundle.verify(side, proof);
        uint256 second = before - gasleft();
        emit log_named_uint("first verify", first);
        emit log_named_uint("second (ticket)", second);
        assertLt(second, first / 10, "a repeat must be a lookup, not a verification");
    }

    /// The ticket is keyed by CONTENT, which is what keeps the trust model intact: a module can only
    /// be satisfied by a proof of exactly the values it is about to act on. One field off, no ticket.
    function test_theTicketIsUselessForAnyOtherSide() public {
        IBundleVerifier.BundleInputs memory side = _side();
        assertTrue(bundle.verify(side, _proof()));

        IBundleVerifier.BundleInputs memory tampered = _side();
        tampered.newLeaf = keccak256("another leaf");
        assertFalse(bundle.wasProven(tampered), "a different leaf has no ticket");

        tampered = _side();
        tampered.principal = side.principal + 1;
        assertFalse(bundle.wasProven(tampered), "a different principal has no ticket");

        tampered = _side();
        tampered.nullRep = keccak256("another nullifier");
        assertFalse(bundle.wasProven(tampered), "a different nullifier has no ticket");
    }

    /// Every field of the statement, one at a time: the adapter's only promise is that the proof
    /// names the same side the caller does, so each field has to be able to break it.
    function test_verify_rejectsEveryEditedField() public {
        bytes memory proof = _proof();
        IBundleVerifier.BundleInputs memory s;

        s = _side();
        s.dealSubject = keccak256("someone else");
        assertFalse(bundle.verify(s, proof), "subject");

        s = _side();
        s.dealId = keccak256("another deal");
        assertFalse(bundle.verify(s, proof), "dealId");

        s = _side();
        s.principal = s.principal + 1;
        assertFalse(bundle.verify(s, proof), "principal");

        s = _side();
        s.repRoot = keccak256("another root");
        assertFalse(bundle.verify(s, proof), "repRoot");

        s = _side();
        s.newLeaf = keccak256("another leaf");
        assertFalse(bundle.verify(s, proof), "newLeaf");

        s = _side();
        s.nullRep = keccak256("another nullifier");
        assertFalse(bundle.verify(s, proof), "nullRep");

        s = _side();
        s.pairTag = keccak256("another pair");
        assertFalse(bundle.verify(s, proof), "pairTag");

        s = _side();
        s.lockCommit = keccak256("another lock");
        assertFalse(bundle.verify(s, proof), "lockCommit");

        s = _side();
        s.lockAmount = s.lockAmount + 1;
        assertFalse(bundle.verify(s, proof), "lockAmount");

        s = _side();
        s.changeNote = keccak256("another change");
        assertFalse(bundle.verify(s, proof), "changeNote");

        s = _side();
        s.nullBond = keccak256("another burn");
        assertFalse(bundle.verify(s, proof), "nullBond");

        s = _side();
        s.bondRoot = keccak256("another notes root");
        assertFalse(bundle.verify(s, proof), "bondRoot");

        // The 2026-09-29 additions: the registry domain, the recovery hints and the panel.
        s = _side();
        s.registryId = keccak256("another registry");
        assertFalse(bundle.verify(s, proof), "registryId");

        s = _side();
        s.hintS = keccak256("another hint");
        assertFalse(bundle.verify(s, proof), "hintS");

        s = _side();
        s.hintK = keccak256("another secret hint");
        assertFalse(bundle.verify(s, proof), "hintK");

        s = _side();
        s.arbiters[1] = keccak256("another arbiter");
        assertFalse(bundle.verify(s, proof), "arbiters");

        // The flag (2026-10-01): a verified side's proof does not pass as an open one.
        s = _side();
        s.verified = false;
        assertFalse(bundle.verify(s, proof), "verified");

        // And nothing above left a ticket behind.
        assertFalse(bundle.wasProven(_side()), "a refused verify proves nothing");
    }

    /// The amplification the interface has no field for: the tier scale is the SERVED token's, so a
    /// proof built for another token's decimals cannot admit this deal (§E.3.14.7).
    function test_verify_rejectsForeignDecimals() public {
        IBundleVerifier.BundleInputs memory side = _side();
        // An 18-decimal token at the same address: the proof's `decimals` no longer matches.
        vm.mockCall(_token(), abi.encodeWithSignature("decimals()"), abi.encode(uint256(18)));
        assertFalse(bundle.verify(side, _proof()), "a foreign scale cannot admit");
    }

    /// A token with no code answers nothing, which decodes to a sentinel no proof can name.
    function test_verify_rejectsATokenWithoutCode() public {
        IBundleVerifier.BundleInputs memory side = _side();
        vm.etch(_token(), "");
        assertFalse(bundle.verify(side, _proof()), "no decimals, no admission");
    }

    /// Fail-closed on the blob itself: too short to carry the public inputs, empty, or a proof of a
    /// different circuit entirely. None of them may revert — a revert-shaped pass is the one failure
    /// mode an adapter must not have.
    function test_verify_rejectsMalformedBlobs() public {
        IBundleVerifier.BundleInputs memory side = _side();
        assertFalse(bundle.verify(side, ""), "empty");
        assertFalse(bundle.verify(side, hex"0011"), "two bytes");
        bytes memory foreign =
            vm.parseJsonBytes(vm.readFile("test/fixtures/proofs/claim.json"), ".proof_with_public_inputs");
        assertFalse(bundle.verify(side, foreign), "another circuit's proof");
        assertFalse(bundle.wasProven(side), "and still no ticket");
    }

    /// A verifier whose Honk deploy failed answers `false` to everything rather than reverting.
    function test_aDeadVerifierFailsClosed() public {
        BundleVerifier dead = new BundleVerifier(hex"fe", ""); // initcode that always reverts
        assertEq(dead.honkVerifier(), address(0), "the deploy failed");
        assertFalse(dead.verify(_side(), _proof()), "and every verify is false");
    }
}
