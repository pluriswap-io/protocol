// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccountVerifier} from "../interfaces/IAccountVerifier.sol";
import {HumanityRegistry} from "../HumanityRegistry.sol";

/// @title RegistryAccountVerifier
/// @notice The real account verifiers behind the frozen `IAccountVerifier` (PROTOCOLO.md §E.3.15.9):
///         `register_account` — the account side of the register bundle, that `leaf0` is bound to the
///         same per-human secret behind the burned `hn`, or (2026-10-01) an open genesis with no human
///         behind it — and `upgrade_account`, an open account verified in place.
/// @dev Same fail-closed shape as `RegistryHumanityVerifier`, minus the root check on registration: that
///      circuit does not re-prove membership. The bundle order does that work — the reputation only trusts
///      an hn the passport has already burned against its own membership proof — and the identical public
///      `hn` across both proofs cannot be satisfied with two different registry domains without breaking
///      Poseidon. The domain is still checked here (the adapter's own read): a proof naming a foreign
///      registry fails closed. The upgrade's root is the module's to gate (`isKnownRoot`), like a claim's.
///
///      Public inputs in circuit order — register_account: `hn`, `leaf0`, `registryId`, `verified`;
///      upgrade_account: `hn`, `registryId`, `repRoot`, `nullRep`, `newLeaf`.
contract RegistryAccountVerifier is IAccountVerifier {
    /// @dev `verify(bytes,bytes32[])` — the generated ultra_honk verifier's only entrypoint.
    bytes4 internal constant VERIFY_SELECTOR = bytes4(keccak256("verify(bytes,bytes32[])"));

    /// @dev The BN254 scalar field — the domain of every public input the circuits prove over.
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev (hn, leaf0, registryId, verified) — must mirror register_account's pub signature order.
    uint256 internal constant PUBLIC_INPUTS = 4;

    /// @dev (hn, registryId, repRoot, nullRep, newLeaf) — must mirror upgrade_account's.
    uint256 internal constant UPGRADE_INPUTS = 5;

    HumanityRegistry public immutable registry;

    /// @dev The generated Honk verifier, deployed from initcode in the constructor. Zero
    ///      (deploy failed) fails every verify.
    address public immutable honkVerifier;

    /// @dev The generated Honk verifier of `upgrade_account` (2026-10-01), deployed the same way. Zero fails
    ///      every upgrade and nothing else.
    address public immutable upgradeHonkVerifier;

    error ZeroRegistry();

    constructor(HumanityRegistry registry_, bytes memory verifierInitcode, bytes memory upgradeInitcode) {
        if (address(registry_) == address(0)) revert ZeroRegistry();
        registry = registry_;
        honkVerifier = _deploy(verifierInitcode);
        upgradeHonkVerifier = _deploy(upgradeInitcode);
    }

    function _deploy(bytes memory initcode) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
    }

    /// @inheritdoc IAccountVerifier
    function verifyAccount(bytes calldata proof, bytes32 hn, bytes32 leaf0) external view returns (bool) {
        return _verifyGenesis(proof, hn, leaf0, true);
    }

    /// @inheritdoc IAccountVerifier
    /// @dev The same circuit with `verified = 0`: the proof must name no human (`hn == 0`), and the genesis it
    ///      opens says `verified = 0` — the circuit pins both.
    function verifyOpenAccount(bytes calldata proof, bytes32 leaf0) external view returns (bool) {
        return _verifyGenesis(proof, bytes32(0), leaf0, false);
    }

    function _verifyGenesis(bytes calldata proof, bytes32 hn, bytes32 leaf0, bool verified)
        internal
        view
        returns (bool)
    {
        if (honkVerifier == address(0)) return false; // deploy failed — fail closed
        // A blob that cannot even carry the public inputs section is malformed: false, never
        // a panic (the empty-pubs path below would be an out-of-bounds read).
        if (proof.length < PUBLIC_INPUTS * 32) return false;
        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof, PUBLIC_INPUTS);
        if (pubs[0] != hn) return false; // the nullifier the passport burned this bundle (zero: open)
        if (pubs[1] != leaf0) return false; // the initial leaf the reputation is inserting
        // The registry domain is a raw bytes32 tag (keccak-derived, may sit over p); the
        // proof names its canonical field element. The pinned mod-p rule applies here,
        // at the adapter boundary — a pub input can never be >= p and still match.
        if (uint256(pubs[2]) != uint256(registry.registryId()) % BN254_P) return false;
        // Which shape: the module asked for one, and the proof has to be of exactly that one.
        if (pubs[3] != (verified ? bytes32(uint256(1)) : bytes32(0))) return false;
        return _verify(honkVerifier, honkProof, pubs);
    }

    /// @inheritdoc IAccountVerifier
    function verifyUpgrade(bytes calldata proof, bytes32 hn, bytes32 repRoot, bytes32 nullRep, bytes32 newLeaf)
        external
        view
        returns (bool)
    {
        if (upgradeHonkVerifier == address(0)) return false; // deploy failed — fail closed
        if (proof.length < UPGRADE_INPUTS * 32) return false;
        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof, UPGRADE_INPUTS);
        if (pubs[0] != hn) return false; // the human the passport burned this bundle
        if (uint256(pubs[1]) != uint256(registry.registryId()) % BN254_P) return false;
        if (pubs[2] != repRoot) return false; // the live root the module gated
        if (pubs[3] != nullRep) return false; // the version nullifier the module will burn
        if (pubs[4] != newLeaf) return false; // the flagged leaf the module will insert
        return _verify(upgradeHonkVerifier, honkProof, pubs);
    }

    /// @dev Split the blob into the trailing public inputs and the proof body. Malformed
    ///      length returns empty pubs, which fails every caller's checks — never reverts.
    function _split(bytes calldata blob, uint256 count) internal pure returns (bytes32[] memory, bytes calldata) {
        if (blob.length < count * 32) {
            return (new bytes32[](0), blob[0:0]);
        }
        uint256 proofLen = blob.length - count * 32;
        bytes32[] memory pubs = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            pubs[i] = bytes32(blob[proofLen + i * 32:proofLen + (i + 1) * 32]);
        }
        return (pubs, blob[0:proofLen]);
    }

    /// @dev Call the generated verifier. `verify` is `view`: staticcall, so the adapter cannot
    ///      even be tricked into a state change; any revert or odd return is `false`.
    function _verify(address verifier, bytes calldata honkProof, bytes32[] memory pubs) internal view returns (bool) {
        (bool ok, bytes memory ret) = verifier.staticcall(abi.encodeWithSelector(VERIFY_SELECTOR, honkProof, pubs));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
