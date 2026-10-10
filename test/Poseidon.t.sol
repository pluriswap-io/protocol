// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {Poseidon} from "../src/packages/libraries/Poseidon.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PrivacyCommitments} from "../src/packages/libraries/PrivacyCommitments.sol";

/// @title Poseidon singleton tests
/// @notice The private layer hashes through the upstream poseidon-solidity DEPLOYMENT, not through
///         a copy compiled in this tree (PROTOCOLO.md §E.5.1). Compiled here, `PoseidonT3`'s runtime
///         is 29,315 B — past EIP-170 — so a linked library is a contract no chain would accept.
/// @dev Two halves, and both are needed. `PoseidonInstalled` pins what the singleton IS: derived by
///      CREATE2 from the pinned submodule initcode, inside EIP-170, circomlib-compatible.
///      `PoseidonAbsent` pins that the protocol actually USES it — every hashing contract must fail
///      closed on a chain where the singleton was never deployed, because a contract that keeps
///      hashing without it is a contract that linked its own oversized copy again.
contract PoseidonInstalledTest is Test {
    /// @dev circomlib `poseidonperm_x5_254_3([1, 2])` — the zero gate of the whole private layer.
    uint256 internal constant CIRCOM_T3_1_2 =
        7853200120776062878684798364095072458815029376092732009249414926327459813530;

    /// @dev EIP-170. The wall the locally compiled library does not clear.
    uint256 internal constant MAX_RUNTIME = 24_576;

    function setUp() public {
        PoseidonSingletons.install();
    }

    function test_singletons_liveAtThePinnedAddresses() public view {
        assertGt(Poseidon.T2.code.length, 0, "T2 not installed");
        assertGt(Poseidon.T3.code.length, 0, "T3 not installed");
    }

    /// The twin of `test_fork_liveCodeMatchesThePinnedInitcode`: the runtime the pinned initcode
    /// installs here is the runtime Arbitrum already holds, byte for byte.
    function test_singletons_matchTheChainRuntime() public view {
        assertEq(keccak256(Poseidon.T2.code), PoseidonSingletons.T2_CODEHASH);
        assertEq(keccak256(Poseidon.T3.code), PoseidonSingletons.T3_CODEHASH);
    }

    /// The finding this whole change exists for: the runtime the protocol hashes with must be
    /// deployable. Our own build of the same source is 29,315 B and is not.
    function test_singletons_fitEIP170() public view {
        assertLe(Poseidon.T2.code.length, MAX_RUNTIME, "T2 over EIP-170");
        assertLe(Poseidon.T3.code.length, MAX_RUNTIME, "T3 over EIP-170");
    }

    function test_t3_matchesTheCircomlibVector() public view {
        assertEq(Poseidon.t3(1, 2), CIRCOM_T3_1_2);
    }

    function test_t2_agreesWithTheCommitmentTwin() public view {
        assertEq(PrivacyCommitments.poseidonT2(bytes32(uint256(1))), bytes32(Poseidon.t2(1)));
    }

    function test_tree_hashesThroughTheSingleton() public {
        PoseidonTree tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, address(this));
        tree.insert(bytes32(uint256(7)));
        assertGt(uint256(tree.root()), 0);
    }
}

/// No singleton anywhere: every hashing path must fail closed, loudly, at the earliest point.
contract PoseidonAbsentTest is Test {
    function test_tree_refusesToDeployWithoutTheSingleton() public {
        vm.expectRevert(abi.encodeWithSelector(Poseidon.PoseidonUnavailable.selector, Poseidon.T3));
        new PoseidonTree(32, DEFAULT_ROOT_HISTORY, address(this));
    }

    function test_commitments_revertWithoutTheSingleton() public {
        vm.expectRevert(abi.encodeWithSelector(Poseidon.PoseidonUnavailable.selector, Poseidon.T3));
        this.hashPair();
    }

    function hashPair() external view returns (bytes32) {
        return PrivacyCommitments.poseidonT3(bytes32(uint256(1)), bytes32(uint256(2)));
    }
}
