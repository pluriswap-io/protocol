// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title What each committed verifier is, pinned
/// @notice Evaluation of 2026-09-28: the adapters deploy whatever initcode they are given, and nothing pinned which
///         initcode that is — CI checks that the vectors did not drift, not that the proofs, verifiers and keys still
///         come out of the Noir in this tree. CI cannot regenerate them (it runs without nargo or bb, on purpose),
///         so this pins them instead: every committed verifier initcode and every off-chain verification key, by
///         hash. Changing a circuit changes its verifier, and this test fails until the new hash is written here —
///         a verifier never changes by accident. `script/Doctor.s.sol` checks a deployment against the same files.
///         Regenerate with the pinned toolchain (circuits/README.md), then update the hash that moved.
contract VerifierPinsTest is Test {
    function _initcodeHash(string memory circuit) internal view returns (bytes32) {
        string memory f = vm.readFile(string.concat("test/fixtures/verifiers/", circuit, ".json"));
        return keccak256(vm.parseJsonBytes(f, ".initcode"));
    }

    function _vkHash(string memory circuit) internal view returns (bytes32) {
        string memory f = vm.readFile(string.concat("test/fixtures/vks/", circuit, ".json"));
        // bb writes the key as bare hex, without the 0x prefix `parseJsonBytes` needs.
        return keccak256(vm.parseBytes(string.concat("0x", vm.parseJsonString(f, ".vk"))));
    }

    function test_onChainVerifiers_arePinned() public view {
        assertEq(_initcodeHash("register_humanity"), 0x2a04e29a9d5415bc8df588b1cdf56da3c49584331b9cfa064576f4836d58b34c);
        assertEq(_initcodeHash("register_account"), 0x119de26c645f2afb4ea77b87e1818d3af1fed7b93915ce7222687d838c44bae3);
        assertEq(_initcodeHash("upgrade_account"), 0xbbc3a65def5523de9100b872b137da11c786b1aa3882e62090695449226e74c0);
        assertEq(_initcodeHash("prepare_side"), 0x2323df427536bb21384ff0aede8be6a5f55eaaf2587de3ad8c3c4593ffed7801);
        assertEq(_initcodeHash("vouch"), 0x35ecb2b51711cf3e2d04dfb58802d69b62bfeab9665d12db3a9efdd731ddcf2e);
        assertEq(_initcodeHash("deposit"), 0x545ba7d92748433da2abc58495e852519567720593d72ffcab2c5ac87d51b45a);
        assertEq(_initcodeHash("claim"), 0xe9c969f7356bfbd05efd16f2a691f9bf83b7f4524cdbd24fc81007eca762c0fc);
        assertEq(_initcodeHash("reabsorb"), 0x4c6e8c6e1120aa52cacf52fe9f833dc7c6fb226c9c50881b1ba2c13782113f11);
        assertEq(_initcodeHash("withdraw"), 0x9de8550b2527ca09ee7d801e0e9d3051b028b413889da04e51e91c1fe058024a);
    }

    function test_offChainKeys_arePinned() public view {
        assertEq(_vkHash("attest_base"), 0x9421f5647cc4132c3684837721d29fdf4b5d2388c2123316336f8d21619fbdaf);
        assertEq(_vkHash("reveal_advanced"), 0x3a24a57b63bdde07d510ef45e125ed4ab65101ccdd4884dfd29650a478b9e035);
        assertEq(_vkHash("prepare_admit"), 0xf168d6c01ffa0ae47382dcd5ac217b041b136a86f39c75a48f89da245337ef65);
    }
}
