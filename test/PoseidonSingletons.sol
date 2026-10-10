// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @title PoseidonSingletons
/// @notice Test-side installer for the pinned poseidon-solidity singletons (PROTOCOLO.md §E.5.1).
/// @dev Production never compiles poseidon-solidity: `PoseidonT3`'s runtime under this tree's
///      compiler settings is 29,315 B, past the EIP-170 wall, so a locally linked library is a
///      contract no chain would accept. What the protocol calls is the upstream DEPLOYMENT —
///      the same address on every EVM, already live on Arbitrum One and Arbitrum Sepolia.
///
///      A test EVM starts empty, so it has to be put there. This does it the way a real chain
///      did it, not by fiat: it etches Arachnid's deterministic-deployment-proxy (69 bytes,
///      pinned in the fixture) and sends it `salt || initcode` from the pinned submodule. The
///      address is DERIVED by CREATE2, never asserted — if the committed initcode ever stopped
///      hashing to the address the contracts pin, `install` would land somewhere else and every
///      private test would fail closed.
library PoseidonSingletons {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant FIXTURE = "test/fixtures/poseidon.json";

    /// @dev `keccak256` of each singleton's runtime AT ITS CANONICAL ADDRESS. solc patches a
    ///      library's own address into its runtime prologue, so these hashes are only meaningful
    ///      there — which is the point: they pin that what the pinned initcode installs locally is
    ///      byte for byte what Arbitrum already holds (`test/fork/Poseidon.fork.t.sol`).
    bytes32 internal constant T2_CODEHASH = 0x08d6790fb052317b05f195f221c35a708c71994bfa65d387fee6158026f8e581;
    bytes32 internal constant T3_CODEHASH = 0x4495c92f7f5db02c3922c3e56cbe427af9cb349a77fd3faf41165afb3137d022;

    error ProxyDeployFailed();
    error WrongAddress(address expected, address got);

    /// @notice Idempotent: installs both singletons at their canonical addresses if absent.
    function install() internal {
        string memory json = vm.readFile(FIXTURE);
        address deployer = vm.parseJsonAddress(json, ".deployer");
        if (deployer.code.length == 0) vm.etch(deployer, vm.parseJsonBytes(json, ".deployerRuntime"));
        _deploy(json, deployer, ".singletons.PoseidonT2");
        _deploy(json, deployer, ".singletons.PoseidonT3");
    }

    function _deploy(string memory json, address deployer, string memory key) private {
        address expected = vm.parseJsonAddress(json, string.concat(key, ".address"));
        if (expected.code.length != 0) return;
        bytes32 salt = vm.parseJsonBytes32(json, string.concat(key, ".salt"));
        bytes memory initcode = vm.parseJsonBytes(json, string.concat(key, ".initcode"));
        (bool ok, bytes memory ret) = deployer.call(bytes.concat(salt, initcode));
        if (!ok || ret.length != 20) revert ProxyDeployFailed();
        address got = address(uint160(bytes20(ret)));
        if (got != expected) revert WrongAddress(expected, got);
    }
}
