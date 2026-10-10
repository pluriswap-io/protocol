// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {PrivacyCommitments} from "../src/packages/libraries/PrivacyCommitments.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title HumanityRegistry tests (V1, PROTOCOLO.md §E.3.15.3 "Registro")
/// @dev The enrollment side of the registry model: decoder gate, one anchor one commitment,
///      and the tree parity that makes the proofs work — after enrolling the vectors' hsk,
///      the on-chain root equals the JS-computed root the committed proof verified against.
contract HumanityRegistryTest is Test {
    string internal vectors;
    PassportDecoderMock internal decoder;
    HumanityRegistry internal registry;
    address internal anchor;

    bytes32 internal hsk;
    bytes32 internal identityCommitment;

    function setUp() public {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        vectors = vm.readFile("test/fixtures/vectors.json");
        hsk = bytes32(vm.parseJsonUint(vectors, ".registry.hsk"));
        identityCommitment = bytes32(vm.parseJsonUint(vectors, ".registry.identity_commitment"));

        // Forge tests start at timestamp 1; the expiry arithmetic (and the mock's
        // expirationTime == 0 sentinel) needs a real clock.
        vm.warp(1_700_000_000);
        decoder = new PassportDecoderMock(200_000, 1 days);
        anchor = makeAddr("anchor");
        decoder.setScore(anchor, 200_000, uint64(block.timestamp + 30 days));

        registry = new HumanityRegistry(
            decoder,
            0, // minScore 0: defer to the decoder's own isHuman
            bytes32(vm.parseJsonUint(vectors, ".registry.registry_id"))
        );
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsZeroDecoder() public {
        vm.expectRevert(HumanityRegistry.ZeroDecoder.selector);
        new HumanityRegistry(IGitcoinPassportDecoder(address(0)), 0, bytes32(uint256(1)));
    }

    function test_constructor_rejectsZeroRegistryId() public {
        vm.expectRevert(HumanityRegistry.ZeroRegistryId.selector);
        new HumanityRegistry(decoder, 0, bytes32(0));
    }

    function test_depth_is20() public view {
        assertEq(uint256(registry.TREE_DEPTH()), 20);
        assertEq(uint256(registry.tree().depth()), 20);
        assertEq(registry.registryId(), bytes32(vm.parseJsonUint(vectors, ".registry.registry_id")));
    }

    // ---------------------------------------------------------------- tree parity (the proofs' anchor)

    function test_emptyRoot_matchesVectors() public view {
        // The deployed depth-20 tree starts where the JS twin started — the root the committed
        // register_humanity proof's membership witness folds from.
        assertEq(uint256(registry.root()), vm.parseJsonUint(vectors, ".registry.empty_root"), "empty root parity");
        assertTrue(registry.isKnownRoot(bytes32(vm.parseJsonUint(vectors, ".registry.empty_root"))));
    }

    function test_enroll_rootMatchesTheProofWitness() public {
        // The identity commitment the test computes with the Solidity twin must be the one
        // the vectors pinned (JS twin) — then enrolling it must reproduce the root the
        // committed proof verified against. If this holds, on-chain tree, JS twin and the
        // Honk proof all sit on the same enrollment state.
        bytes32 computed = registry.identityCommitmentOf(hsk);
        assertEq(computed, identityCommitment, "twin commitment != vectors commitment");

        vm.prank(anchor);
        vm.expectEmit(true, true, false, true, address(registry));
        emit HumanityRegistry.Enrolled(
            anchor, identityCommitment, 0, bytes32(vm.parseJsonUint(vectors, ".registry.root"))
        );
        registry.enroll(identityCommitment);

        assertEq(
            uint256(registry.root()),
            vm.parseJsonUint(vectors, ".registry.root"),
            "post-enroll root must equal the proof's root"
        );
        assertTrue(registry.isKnownRoot(bytes32(vm.parseJsonUint(vectors, ".registry.root"))));
        assertTrue(registry.enrolled(anchor));
    }

    // ---------------------------------------------------------------- enrollment rules

    function test_enroll_onePerAnchor() public {
        // Computed before the expectRevert: argument evaluation makes external calls,
        // and an unconsumed expectRevert would grab the view call instead of the enroll.
        bytes32 otherCommitment = registry.identityCommitmentOf(bytes32(uint256(0xdead)));
        vm.startPrank(anchor);
        registry.enroll(identityCommitment);
        vm.expectRevert(HumanityRegistry.AnchorAlreadyEnrolled.selector);
        registry.enroll(otherCommitment);
        vm.stopPrank();
    }

    function test_enroll_rejectsZeroCommitment() public {
        vm.prank(anchor);
        vm.expectRevert(HumanityRegistry.ZeroCommitment.selector);
        registry.enroll(bytes32(0));
    }

    function test_enroll_requiresDecoderGate() public {
        // A wallet with no live attestation cannot enroll: the decoder reverts on getScore,
        // and the registry reads that as NotHuman (fail closed, never a revert-shaped pass).
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(HumanityRegistry.NotHuman.selector);
        registry.enroll(identityCommitment);

        // Expired attestation: same fail-closed read.
        decoder.setScore(anchor, 200_000, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 2);
        vm.prank(anchor);
        vm.expectRevert(HumanityRegistry.NotHuman.selector);
        registry.enroll(identityCommitment);
    }

    function test_enroll_pinnedThresholdFailsBelow() public {
        // minScore > 0 pins the threshold in the registry: the decoder's own 200_000 is then
        // not enough against a 300_000 policy.
        HumanityRegistry strict = new HumanityRegistry(decoder, 300_000, registry.registryId());
        vm.prank(anchor);
        vm.expectRevert(HumanityRegistry.NotHuman.selector);
        strict.enroll(identityCommitment);
    }

    function test_enroll_pausedDecoderFailsClosed() public {
        decoder.setPaused(true);
        vm.prank(anchor);
        vm.expectRevert(HumanityRegistry.NotHuman.selector);
        registry.enroll(identityCommitment);
    }
}
