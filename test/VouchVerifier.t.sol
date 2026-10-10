// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";

/// @title The vouch, against the real proof
/// @dev PROTOCOLO.md Anexo R, 2026-09-29: across from a pool, a human stands in for the pool's side of the pair
///      rule. The shared verifier carries that statement next to `prepare_side`, behind `verifyVouch`. This suite
///      drives it with the COMMITTED `vouch` proof — the prepare account vouching for its sample counterparty in the
///      sample deal — and pins the same three promises as the bundle: exactly the vouch that was proven, nothing
///      else, and a content-keyed transient ticket.
contract VouchVerifierTest is Test {
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    BundleVerifier internal bundle;
    string internal vectors;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/vectors.json");
        bundle = new BundleVerifier(
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/prepare_side.json"), ".initcode"),
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/vouch.json"), ".initcode")
        );
    }

    function _b(string memory path) internal view returns (bytes32) {
        return bytes32(vm.parseJsonUint(vectors, path));
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile("test/fixtures/proofs/vouch.json"), ".proof_with_public_inputs");
    }

    /// The vouch exactly as the circuit proved it: the same deal, root, tag and panel `prepare_side` names.
    function _vouch() internal view returns (IBundleVerifier.VouchInputs memory) {
        return IBundleVerifier.VouchInputs({
            dealId: _b(".prepare.deal_id"),
            repRoot: _b(".prepare.root"),
            pairTag: _b(".prepare.pair_tag"),
            registryId: _b(".prepare.registry_id"),
            arbiters: [_b(".prepare.arbiters[0]"), _b(".prepare.arbiters[1]"), _b(".prepare.arbiters[2]")],
            verified: true,
            poolId: _b(".prepare.pool_id"),
            operatorTag: _b(".prepare.operator_tag"),
            cpTag: _b(".prepare.pool_cp_tag")
        });
    }

    /// The sample pool's subject, as the passport answers it: the pool id the vouch names is that subject mod p.
    function test_thePoolIdIsTheSamplePoolsSubject() public view {
        address pool = vm.parseJsonAddress(vectors, ".builders.pool.address");
        uint256 subject = uint256(keccak256(abi.encode("pluri:pool", pool)));
        assertEq(subject % BN254_P, uint256(_b(".prepare.pool_id")), "the field element of the pool's subject");
        assertEq(_b(".builders.pool.pool_id"), _b(".prepare.pool_id"), "one sample pool");
    }

    /// The adapter reduces the pool id like a deal id: the raw subject names the same pool.
    function test_verifyVouch_acceptsTheRawPoolSubject() public {
        IBundleVerifier.VouchInputs memory v = _vouch();
        v.poolId = keccak256(abi.encode("pluri:pool", vm.parseJsonAddress(vectors, ".builders.pool.address")));
        assertTrue(bundle.verifyVouch(v, _proof()), "the raw subject");
    }

    function test_verifyVouch_theRealVouch() public {
        IBundleVerifier.VouchInputs memory v = _vouch();
        assertFalse(bundle.wasVouched(v), "no ticket before the proof");
        assertTrue(bundle.verifyVouch(v, _proof()), "the committed proof verifies");
        assertTrue(bundle.wasVouched(v), "and leaves its ticket");
    }

    function test_verifyVouch_isIdempotentWithinTheTransaction() public {
        IBundleVerifier.VouchInputs memory v = _vouch();
        bytes memory proof = _proof();
        uint256 before = gasleft();
        bundle.verifyVouch(v, proof);
        uint256 first = before - gasleft();
        before = gasleft();
        bundle.verifyVouch(v, proof);
        uint256 second = before - gasleft();
        emit log_named_uint("first vouch", first);
        assertLt(second, first / 10, "a repeat must be a lookup, not a verification");
    }

    /// Every field of the statement, one at a time.
    function test_verifyVouch_rejectsEveryEditedField() public {
        bytes memory proof = _proof();
        IBundleVerifier.VouchInputs memory v;

        v = _vouch();
        v.dealId = keccak256("another deal");
        assertFalse(bundle.verifyVouch(v, proof), "dealId");

        v = _vouch();
        v.repRoot = keccak256("another root");
        assertFalse(bundle.verifyVouch(v, proof), "repRoot");

        // The voucher's flag (2026-10-01): a verified human's vouch does not pass as an open account's.
        v = _vouch();
        v.verified = false;
        assertFalse(bundle.verifyVouch(v, proof), "verified");

        v = _vouch();
        v.pairTag = keccak256("another pair");
        assertFalse(bundle.verifyVouch(v, proof), "pairTag");

        v = _vouch();
        v.registryId = keccak256("another registry");
        assertFalse(bundle.verifyVouch(v, proof), "registryId");

        v = _vouch();
        v.arbiters[2] = keccak256("another arbiter");
        assertFalse(bundle.verifyVouch(v, proof), "arbiters");

        // The pool's side (Anexo R, 2026-10-05): another pool, another operator, another counterparty.
        v = _vouch();
        v.poolId = bytes32(uint256(v.poolId) + 1);
        assertFalse(bundle.verifyVouch(v, proof), "poolId");

        v = _vouch();
        v.operatorTag = keccak256("another operator");
        assertFalse(bundle.verifyVouch(v, proof), "operatorTag");

        v = _vouch();
        v.cpTag = keccak256("another counterparty");
        assertFalse(bundle.verifyVouch(v, proof), "cpTag");

        assertFalse(bundle.wasVouched(_vouch()), "a refused vouch proves nothing");
    }

    /// The two tickets are different permissions: a vouch is not a side, and a side is not a vouch.
    function test_aVouchTicketIsNoSideTicket() public {
        IBundleVerifier.VouchInputs memory v = _vouch();
        assertTrue(bundle.verifyVouch(v, _proof()));
        IBundleVerifier.BundleInputs memory side;
        side.dealId = v.dealId;
        side.repRoot = v.repRoot;
        side.pairTag = v.pairTag;
        side.registryId = v.registryId;
        side.arbiters = v.arbiters;
        assertFalse(bundle.wasProven(side), "a vouch does not admit a side");
    }

    function test_verifyVouch_rejectsMalformedBlobs() public {
        IBundleVerifier.VouchInputs memory v = _vouch();
        assertFalse(bundle.verifyVouch(v, ""), "empty");
        assertFalse(bundle.verifyVouch(v, hex"0011"), "two bytes");
        bytes memory side =
            vm.parseJsonBytes(vm.readFile("test/fixtures/proofs/prepare_side.json"), ".proof_with_public_inputs");
        assertFalse(bundle.verifyVouch(v, side), "a side's proof is not a vouch");
        assertFalse(bundle.wasVouched(v), "and still no ticket");
    }

    function test_aDeadVouchVerifierFailsClosed() public {
        BundleVerifier dead = new BundleVerifier(
            vm.parseJsonBytes(vm.readFile("test/fixtures/verifiers/prepare_side.json"), ".initcode"), hex"fe"
        );
        assertEq(dead.vouchHonkVerifier(), address(0), "the deploy failed");
        assertTrue(dead.honkVerifier() != address(0), "the side verifier is untouched");
        assertFalse(dead.verifyVouch(_vouch(), _proof()), "and every vouch is false");
    }
}
