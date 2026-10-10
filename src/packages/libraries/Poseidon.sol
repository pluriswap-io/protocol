// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Poseidon
/// @notice BN254 Poseidon over the pinned poseidon-solidity singletons (PROTOCOLO.md §E.5.1).
/// @dev The protocol does NOT compile poseidon-solidity into this tree. Built with our settings
///      (solc 0.8.28, via_ir, optimizer 200) `PoseidonT3`'s runtime is 29,315 B — 4,739 B past the
///      EIP-170 wall — so a linked library here is a contract no chain enforcing the limit would
///      accept; only a test EVM, which does not enforce it, would let it through. What upstream
///      ships instead is a DEPLOYMENT: a pre-signed CREATE2 blob whose runtime does fit, pushed
///      through Arachnid's deterministic-deployment-proxy to the same address on every EVM. Both
///      singletons are already live on Arbitrum One and Arbitrum Sepolia.
///
///      So Poseidon is treated the way the Honk verifiers are (§E.3.15.9, V1–V3): foreign bytecode
///      we never compile, called by address and selector, never linked. The addresses below are
///      derived — not asserted — by `CREATE2(deployer, salt, initcode)` over the initcode pinned
///      in `lib/poseidon-solidity`, and `test/fixtures/poseidon.json` carries that derivation for
///      the tests, regenerated under a CI drift gate (`bun poseidon:fixture`).
///
///      Fail-closed: a `staticcall` into an address with no code SUCCEEDS with empty returndata,
///      which would silently hash everything to zero. Every call therefore checks the return size,
///      and a chain without the singleton reverts `PoseidonUnavailable` at the first hash — which
///      for `PoseidonTree` is its own constructor.
library Poseidon {
    /// @dev poseidon-solidity `PoseidonT2` — one input. `CREATE2(0x4e59…, 0x…25651515, initcode)`.
    address internal constant T2 = 0x22233340039aAB0C858bc6086f508d9A4f2fA4db;
    /// @dev poseidon-solidity `PoseidonT3` — two inputs. Same deployer, same salt, other initcode.
    address internal constant T3 = 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93;

    /// @dev `hash(uint256[1])` and `hash(uint256[2])` — the singletons' only entrypoints.
    bytes4 private constant T2_HASH = 0x9d036e71;
    bytes4 private constant T3_HASH = 0x561558fe;

    error PoseidonUnavailable(address singleton);

    function t2(uint256 x) internal view returns (uint256) {
        return _hash(T2, abi.encodeWithSelector(T2_HASH, x));
    }

    function t3(uint256 a, uint256 b) internal view returns (uint256) {
        return _hash(T3, abi.encodeWithSelector(T3_HASH, a, b));
    }

    function _hash(address singleton, bytes memory payload) private view returns (uint256) {
        (bool ok, bytes memory ret) = singleton.staticcall(payload);
        // An absent singleton answers `ok` with nothing; a present one always answers 32 bytes.
        if (!ok || ret.length != 32) revert PoseidonUnavailable(singleton);
        return abi.decode(ret, (uint256));
    }
}
