// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Poseidon} from "../src/packages/libraries/Poseidon.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title PoseidonTree tests (F1, PROTOCOLO.md §E.3.15.11)
/// @dev Behavior first: insert, root ring buffer, nullifiers, ownership, field hygiene.
contract PoseidonTreeTest is Test {
    uint8 internal constant DEPTH = 8;

    /// @dev circomlib PoseidonT3([1, 2]) — pins the BN254 params so circuits and contracts
    ///      agree. Source: iden3/circomlibjs `test/poseidon.js`, `poseidonperm_x5_254_3`.
    uint256 internal constant CIRCOM_T3_1_2 =
        7853200120776062878684798364095072458815029376092732009249414926327459813530;

    bytes32 internal constant LEAF_A = bytes32(uint256(0xA));
    bytes32 internal constant LEAF_B = bytes32(uint256(0xB));
    bytes32 internal constant NULLIFIER = keccak256("nullifier-a");

    PoseidonTree internal tree;

    function setUp() public {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        tree = new PoseidonTree(DEPTH, MIN_ROOT_HISTORY, address(this));
    }

    // ---------------------------------------------------------------- primitives

    function test_poseidon_matchesCircomVector() public view {
        assertEq(Poseidon.t3(1, 2), CIRCOM_T3_1_2);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsBadDepth() public {
        vm.expectRevert(PoseidonTree.BadDepth.selector);
        new PoseidonTree(0, DEFAULT_ROOT_HISTORY, address(this));
        // 33 = PoseidonTree.MAX_DEPTH + 1 (qualified contract-constant reads from
        // another file trip solc 9582 here; the contract re-checks the bound itself).
        vm.expectRevert(PoseidonTree.BadDepth.selector);
        new PoseidonTree(33, DEFAULT_ROOT_HISTORY, address(this));
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(PoseidonTree.ZeroOwner.selector);
        new PoseidonTree(DEPTH, DEFAULT_ROOT_HISTORY, address(0));
    }

    function test_initialRoot_isKnownAndNonZero() public view {
        bytes32 r0 = tree.root();
        assertTrue(r0 != bytes32(0), "empty root is zero");
        assertTrue(tree.isKnownRoot(r0), "empty root not known");
        assertEq(tree.nextIndex(), 0);
    }

    // ---------------------------------------------------------------- insert

    function test_insert_firstLeaf() public {
        bytes32 before = tree.root();
        (uint256 index, bytes32 newRoot) = tree.insert(LEAF_A);
        assertEq(index, 0);
        assertTrue(newRoot != before, "root did not move");
        assertEq(tree.root(), newRoot);
        assertTrue(tree.isKnownRoot(newRoot));
        assertEq(tree.nextIndex(), 1);
    }

    function test_insert_movesRootForward() public {
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root2) = tree.insert(LEAF_B);
        assertTrue(root2 != root1, "root did not move");
        assertTrue(tree.isKnownRoot(root1), "older root evicted too early");
        assertTrue(tree.isKnownRoot(root2));
        assertEq(tree.nextIndex(), 2);
    }

    function test_insert_isDeterministic() public {
        PoseidonTree other = new PoseidonTree(DEPTH, MIN_ROOT_HISTORY, address(this));
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root1b) = other.insert(LEAF_A);
        assertEq(root1, root1b);
        (, bytes32 root2) = tree.insert(LEAF_B);
        (, bytes32 root2b) = other.insert(LEAF_B);
        assertEq(root2, root2b);
    }

    function test_insert_rejectsZeroLeaf() public {
        vm.expectRevert(PoseidonTree.ZeroLeaf.selector);
        tree.insert(bytes32(0));
        assertEq(tree.nextIndex(), 0);
    }

    function test_insert_onlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.insert(LEAF_A);
    }

    function test_insert_treeFull() public {
        PoseidonTree tiny = new PoseidonTree(1, MIN_ROOT_HISTORY, address(this));
        tiny.insert(LEAF_A);
        tiny.insert(LEAF_B);
        vm.expectRevert(PoseidonTree.TreeFull.selector);
        tiny.insert(bytes32(uint256(0xC)));
        assertEq(tiny.nextIndex(), 2);
    }

    // ---------------------------------------------------------------- root ring buffer

    function test_ringBuffer_evictsOldRoots() public {
        bytes32 initial = tree.root();
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root2) = tree.insert(LEAF_B);
        for (uint256 i = 2; i < tree.rootHistory() + 1; i++) {
            tree.insert(bytes32(uint256(0x1000 + i)));
        }
        assertFalse(tree.isKnownRoot(initial), "initial root should be evicted");
        assertFalse(tree.isKnownRoot(root1), "root1 should be evicted");
        assertTrue(tree.isKnownRoot(root2), "root2 should still be known");
        assertTrue(tree.isKnownRoot(tree.root()));
    }

    /// The account tree is SHARED: every activation and every `claim` of every subject inserts a
    /// leaf, so the window is denominated in other people's deals, not in your own. A two-sided
    /// private deal is ~4 inserts, so a 64-root ring is ~16 deals of tolerance between the moment a
    /// prover builds a proof and the moment it lands -- under a minute of protocol traffic. The
    /// window has to hold a human-scale delay: relayer queueing, a wallet confirmation, a retry.
    function test_ringBuffer_holdsAHumanScaleWindow() public {
        PoseidonTree busy = new PoseidonTree(10, DEFAULT_ROOT_HISTORY, address(this));
        (, bytes32 oldRoot) = busy.insert(LEAF_A);
        for (uint256 i = 0; i < 300; i++) {
            busy.insert(bytes32(uint256(0x2000 + i)));
        }
        // 300 inserts is ~75 two-sided private deals. At the old 64-root window this root died
        // after 16 of them; a prover who queued behind other people's traffic lost their proof.
        assertTrue(busy.isKnownRoot(oldRoot), "a proof built 300 inserts ago must still verify");
    }

    /// The window is per tree, but it is not a free knob: below the floor a shared tree stops
    /// holding a human-scale delay, which is the whole finding.
    function test_constructor_boundsTheWindow() public {
        vm.expectRevert(PoseidonTree.BadRootHistory.selector);
        new PoseidonTree(DEPTH, MIN_ROOT_HISTORY - 1, address(this));
        vm.expectRevert(PoseidonTree.BadRootHistory.selector);
        new PoseidonTree(DEPTH, MAX_ROOT_HISTORY + 1, address(this));
    }

    /// `isKnownRoot` is on the hot path of every activation, claim, withdraw and register-verify
    /// (seven on-chain call sites). It must not be a scan of the whole window: a miss on a full
    /// ring of N roots costs N cold SLOADs, so a bigger window would price itself out.
    function test_isKnownRoot_isConstantTime() public {
        for (uint256 i = 0; i < 200; i++) {
            tree.insert(bytes32(uint256(0x3000 + i)));
        }
        vm.cool(address(tree));
        uint256 gas = gasleft();
        this.probeRoot(bytes32(uint256(0xdead)));
        uint256 miss = gas - gasleft();
        assertLt(miss, 12_000, "isKnownRoot scans the window instead of looking it up");
    }

    function probeRoot(bytes32 root_) external view returns (bool) {
        return tree.isKnownRoot(root_);
    }

    // ---------------------------------------------------------------- nullifiers

    function test_spend_burnsNullifierOnce() public {
        tree.spend(NULLIFIER);
        assertTrue(tree.isSpent(NULLIFIER));
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        tree.spend(NULLIFIER);
    }

    function test_spend_defaultUnspent() public view {
        assertFalse(tree.isSpent(NULLIFIER));
    }

    function test_spend_onlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.spend(NULLIFIER);
    }

    // ---------------------------------------------------------------- max depth

    function test_maxDepth_tree() public {
        // 32 = PoseidonTree.MAX_DEPTH (see note in test_constructor_rejectsBadDepth).
        PoseidonTree deep = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, address(this));
        bytes32 before = deep.root();
        (uint256 index, bytes32 newRoot) = deep.insert(LEAF_A);
        assertEq(index, 0);
        assertTrue(newRoot != before, "root did not move");
        assertTrue(deep.isKnownRoot(newRoot));
        assertEq(deep.nextIndex(), 1);
    }
}
