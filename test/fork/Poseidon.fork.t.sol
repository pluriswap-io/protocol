// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Poseidon} from "../../src/packages/libraries/Poseidon.sol";
import {PoseidonSingletons} from "../PoseidonSingletons.sol";

/// @dev Arbitrum fork against the pinned poseidon-solidity singletons (PROTOCOLO.md §E.5.1). Skipped
///      unless ARBITRUM_RPC_URL is set; ARBITRUM_SEPOLIA_RPC_URL adds the testnet leg.
///
///      What the unit tests prove is that the committed initcode DERIVES the pinned addresses. What
///      only a fork can prove is that the chain the protocol deploys to already holds that exact
///      runtime — the whole reason the library is not compiled here. `PoseidonT3` is live on both
///      Arbitrum chains; `PoseidonT2` is not yet, so the assertion is conditional: if there is code
///      at the address it must be ours, and the deploy script (`script/Poseidon.s.sol`) puts it
///      there when there is not.
contract PoseidonForkTest is Test {
    uint256 internal constant CIRCOM_T3_1_2 =
        7853200120776062878684798364095072458815029376092732009249414926327459813530;
    uint256 internal constant MAX_RUNTIME = 24_576;

    function _fork(string memory key) internal returns (bool) {
        string memory rpc = vm.envOr(key, string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        return true;
    }

    /// The finding in one assertion: on the real chain, the hasher the protocol calls is deployed
    /// and fits EIP-170. Our own build of the same source is 29,315 B and could never be here.
    function test_fork_t3_isLiveAndFits() public {
        vm.skip(!_fork("ARBITRUM_RPC_URL"));
        assertGt(Poseidon.T3.code.length, 0, "PoseidonT3 missing on Arbitrum One");
        assertLe(Poseidon.T3.code.length, MAX_RUNTIME, "live PoseidonT3 over EIP-170");
        assertEq(Poseidon.t3(1, 2), CIRCOM_T3_1_2, "live PoseidonT3 is not circomlib");
    }

    function test_fork_sepolia_t3_isLiveAndFits() public {
        vm.skip(!_fork("ARBITRUM_SEPOLIA_RPC_URL"));
        assertGt(Poseidon.T3.code.length, 0, "PoseidonT3 missing on Arbitrum Sepolia");
        assertEq(Poseidon.t3(1, 2), CIRCOM_T3_1_2, "live PoseidonT3 is not circomlib");
    }

    /// The live runtime must be byte-identical to what the committed initcode installs. The CREATE2
    /// address is already a commitment to the initcode; this checks the commitment held on the chain
    /// the protocol actually deploys to, against the same hash the unit tests pin locally.
    function test_fork_liveCodeMatchesThePinnedInitcode() public {
        vm.skip(!_fork("ARBITRUM_RPC_URL"));
        assertEq(keccak256(Poseidon.T3.code), PoseidonSingletons.T3_CODEHASH, "live PoseidonT3 is not the fixture");
    }

    /// `PoseidonT2` is not on Arbitrum yet. Whatever is there — nothing, or ours — must be ours.
    function test_fork_t2_isEitherAbsentOrOurs() public {
        vm.skip(!_fork("ARBITRUM_RPC_URL"));
        if (Poseidon.T2.code.length == 0) return;
        assertEq(keccak256(Poseidon.T2.code), PoseidonSingletons.T2_CODEHASH, "live PoseidonT2 is not the fixture");
    }
}
