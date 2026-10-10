// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Poseidon} from "../src/packages/libraries/Poseidon.sol";

/// @title PoseidonEnsurer
/// @notice Puts the pinned poseidon-solidity singletons on a chain that does not have them yet
///         (PROTOCOLO.md §E.5.1). Idempotent: a singleton that already has code is left alone.
/// @dev The private layer hashes through fixed addresses, never through a library linked into this
///      tree — our own build of `PoseidonT3` is 29,315 B, past EIP-170. Those addresses are the
///      CREATE2 of upstream's pre-signed initcode through Arachnid's deterministic-deployment-proxy,
///      so ensuring them is exactly: send `salt || initcode` to the proxy and check where it landed.
///
///      On Arbitrum One and Arbitrum Sepolia `PoseidonT3` is already live; `PoseidonT2` is not, so
///      this runs once per chain before anything in the private layer is deployed. Deploying the
///      proxy itself is deliberately NOT this script's job: it is a keyless Nick's-method deployment
///      with its own pre-signed transaction, so a missing proxy fails loudly here rather than being
///      papered over with a different factory — which would mean different addresses.
///
///      Inherit it (`is PoseidonEnsurer`) from the private-layer deploy scripts and call
///      `ensurePoseidon()` inside their broadcast, or run `EnsurePoseidon` below on its own:
///      `forge script script/Poseidon.s.sol:EnsurePoseidon --rpc-url $RPC --broadcast`
abstract contract PoseidonEnsurer is Script {
    using stdJson for string;

    string internal constant FIXTURE = "test/fixtures/poseidon.json";

    error DeterministicProxyMissing(address proxy);
    error SingletonDeployFailed(string name);
    error SingletonWrongAddress(string name, address expected, address got);

    /// @notice Deploys whichever singletons are absent. Must run inside a broadcast.
    function ensurePoseidon() internal {
        string memory json = vm.readFile(FIXTURE);
        address proxy = json.readAddress(".deployer");
        if (proxy.code.length == 0) revert DeterministicProxyMissing(proxy);
        _ensure(json, proxy, "PoseidonT2");
        _ensure(json, proxy, "PoseidonT3");
    }

    function _ensure(string memory json, address proxy, string memory name) private {
        string memory key = string.concat(".singletons.", name);
        address expected = json.readAddress(string.concat(key, ".address"));
        if (expected.code.length != 0) {
            console.log("poseidon: %s already live at %s", name, expected);
            return;
        }
        bytes32 salt = json.readBytes32(string.concat(key, ".salt"));
        bytes memory initcode = json.readBytes(string.concat(key, ".initcode"));
        (bool ok, bytes memory ret) = proxy.call(bytes.concat(salt, initcode));
        if (!ok || ret.length != 20) revert SingletonDeployFailed(name);
        address got = address(uint160(bytes20(ret)));
        if (got != expected) revert SingletonWrongAddress(name, expected, got);
        console.log("poseidon: deployed %s at %s", name, got);
    }

    function _key() internal view virtual returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }
}

/// @notice `PoseidonEnsurer` on its own, for a chain that needs the singletons and nothing else.
contract EnsurePoseidon is PoseidonEnsurer {
    function run() external {
        vm.startBroadcast(_key());
        ensurePoseidon();
        vm.stopBroadcast();
    }
}
