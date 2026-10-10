// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBundleVerifier} from "../interfaces/IBundleVerifier.sol";

/// @title BundleVerifier
/// @notice The real `prepare_side` verifier behind the frozen `IBundleVerifier`
///         (PROTOCOLO.md §E.3.15.4, 2026-09-23): one ultra_honk proof covering one side of an
///         activation — its passport, its admission and, when the deal carries bonds, its split.
///
/// @dev Fail-closed everywhere, like every other adapter: a malformed blob, an argument the proof's
///      public inputs do not name, a failed deploy, or any revert inside the generated verifier
///      reads as `false` — never as a revert-shaped pass.
///
///      The proof blob is `proof || public_inputs` (bb's layout): the trailing 672 bytes are the
///      twenty-one public inputs in circuit order. Twenty must match the caller's `BundleInputs`
///      exactly (the flag as 0 or 1); the fifth is `decimals`, which the interface has no field for because the
///      adapter reads it from the SERVED token and requires the proof to have used that value — the
///      tier scale is `UNIT = 250 * 10^decimals`, so a proof scaled for another token's decimals
///      must not admit this deal (§E.3.14.7, and the same amplification `PrepareAdmitVerifier` does).
///
///      Two encodings that have bitten before and are pinned here:
///      * addresses are field elements RIGHT-aligned — `bytes32(uint256(uint160(token)))`, never
///        `bytes32(bytes20)`;
///      * `dealId` is a raw keccak tag that may sit above the BN254 modulus, so it is compared
///        reduced, which is the pinned mod-p rule at the adapter boundary.
///
///      The ticket lives in TRANSIENT storage (EIP-1153, Cancun — the same facility the kernel's
///      reentrancy guard uses). It is keyed by the hash of the inputs, so it can only satisfy a
///      module that is about to act on exactly those values, and it is gone when the transaction
///      ends: permission to assemble a bundle cannot be banked.
contract BundleVerifier is IBundleVerifier {
    /// @dev `verify(bytes,bytes32[])` — the generated ultra_honk verifier's only entrypoint.
    bytes4 internal constant VERIFY_SELECTOR = bytes4(keccak256("verify(bytes,bytes32[])"));

    /// @dev `decimals()` of the served ERC-20 — the tier scale is the token's own.
    bytes4 internal constant DECIMALS_SELECTOR = bytes4(keccak256("decimals()"));

    /// @dev The twenty-one public inputs of `prepare_side`, in its declared order (the last is the flag, 2026-10-01).
    uint256 internal constant PUBLIC_INPUTS = 21;

    /// @dev The eight public inputs of `vouch`: dealId, repRoot, pairTag, registryId, arbiters[3], verified.
    uint256 internal constant VOUCH_INPUTS = 11;

    /// @dev Separates a vouch's ticket from a side's, whatever their encodings happen to be.
    bytes32 internal constant VOUCH_TICKET = keccak256("pluri:bundle-verifier:vouch");

    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev The generated Honk verifier, deployed from initcode in the constructor. Zero (deploy
    ///      failed) fails every verify.
    address public immutable honkVerifier;

    /// @dev The generated Honk verifier of `vouch` (Anexo R, 2026-09-29), deployed the same way. Zero fails every
    ///      vouch and nothing else.
    address public immutable vouchHonkVerifier;

    constructor(bytes memory verifierInitcode, bytes memory vouchInitcode) {
        honkVerifier = _deploy(verifierInitcode);
        vouchHonkVerifier = _deploy(vouchInitcode);
    }

    function _deploy(bytes memory initcode) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
    }

    /// @inheritdoc IBundleVerifier
    function verify(BundleInputs calldata inputs, bytes calldata proof) external returns (bool) {
        bytes32 key = _key(inputs);
        if (_ticket(key)) return true; // already proven in this transaction
        if (honkVerifier == address(0)) return false; // deploy failed — fail closed
        if (proof.length < PUBLIC_INPUTS * 32) return false; // cannot even carry the public inputs

        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof, PUBLIC_INPUTS);
        if (!_namesTheSameSide(inputs, pubs)) return false;
        if (!_verify(honkVerifier, honkProof, pubs)) return false;

        assembly ("memory-safe") {
            tstore(key, 1)
        }
        return true;
    }

    /// @inheritdoc IBundleVerifier
    function wasProven(BundleInputs calldata inputs) external view returns (bool) {
        return _ticket(_key(inputs));
    }

    /// @inheritdoc IBundleVerifier
    /// @dev The same shape as `verify`, against the `vouch` circuit: a blob of `proof || 11 public inputs`, every
    ///      one of which must be the caller's, and a ticket of its own.
    function verifyVouch(VouchInputs calldata inputs, bytes calldata proof) external returns (bool) {
        bytes32 key = _vouchKey(inputs);
        if (_ticket(key)) return true;
        if (vouchHonkVerifier == address(0)) return false;
        if (proof.length < VOUCH_INPUTS * 32) return false;

        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof, VOUCH_INPUTS);
        if (!_namesTheSameVouch(inputs, pubs)) return false;
        if (!_verify(vouchHonkVerifier, honkProof, pubs)) return false;

        assembly ("memory-safe") {
            tstore(key, 1)
        }
        return true;
    }

    /// @inheritdoc IBundleVerifier
    function wasVouched(VouchInputs calldata inputs) external view returns (bool) {
        return _ticket(_vouchKey(inputs));
    }

    function _namesTheSameVouch(VouchInputs calldata i, bytes32[] memory pubs) internal pure returns (bool) {
        if (uint256(pubs[0]) != uint256(i.dealId) % BN254_P) return false;
        if (pubs[1] != i.repRoot) return false;
        if (pubs[2] != i.pairTag) return false;
        if (uint256(pubs[3]) != uint256(i.registryId) % BN254_P) return false;
        for (uint256 k; k < 3; k++) {
            if (pubs[4 + k] != i.arbiters[k]) return false;
        }
        if (pubs[7] != _bit(i.verified)) return false;
        // The pool's side (Anexo R, 2026-10-05). The pool id is the pool's subject, which may sit over p like a
        // deal id: the proof names its canonical field element. The two tags are Poseidon outputs, compared raw.
        if (uint256(pubs[8]) != uint256(i.poolId) % BN254_P) return false;
        if (pubs[9] != i.operatorTag) return false;
        if (pubs[10] != i.cpTag) return false;
        return true;
    }

    function _vouchKey(VouchInputs calldata inputs) internal pure returns (bytes32) {
        return keccak256(abi.encode(VOUCH_TICKET, inputs));
    }

    /// @dev Every public input against the caller's values. The order is the circuit's, and a
    ///      mismatch anywhere is `false` — this is the whole of what the adapter promises.
    function _namesTheSameSide(BundleInputs calldata i, bytes32[] memory pubs) internal view returns (bool) {
        if (pubs[0] != i.dealSubject) return false;
        // The raw keccak tag may sit over p; the proof names its canonical field element.
        if (uint256(pubs[1]) != uint256(i.dealId) % BN254_P) return false;
        if (pubs[2] != bytes32(uint256(uint160(i.token)))) return false; // raw address < p always
        if (pubs[3] != bytes32(i.principal)) return false; // raw amount; >= p can never match
        // The scale belongs to the served token, not to the prover.
        if (_decimalsOf(i.token) != uint256(pubs[4])) return false;
        if (pubs[5] != i.repRoot) return false;
        if (pubs[6] != i.newLeaf) return false;
        if (pubs[7] != i.nullRep) return false;
        if (pubs[8] != i.pairTag) return false;
        if (pubs[9] != i.lockCommit) return false;
        if (pubs[10] != bytes32(i.lockAmount)) return false;
        if (pubs[11] != i.changeNote) return false;
        if (pubs[12] != i.nullBond) return false;
        if (pubs[13] != i.bondRoot) return false;
        // The registry domain is a keccak tag that may sit over p; the proof names its field element.
        if (uint256(pubs[14]) != uint256(i.registryId) % BN254_P) return false;
        if (pubs[15] != i.hintS) return false;
        if (pubs[16] != i.hintK) return false;
        for (uint256 k; k < 3; k++) {
            if (pubs[17 + k] != i.arbiters[k]) return false;
        }
        // The flag, as the circuit names it: 0 or 1, nothing else.
        if (pubs[20] != _bit(i.verified)) return false;
        return true;
    }

    function _bit(bool b) internal pure returns (bytes32) {
        return b ? bytes32(uint256(1)) : bytes32(0);
    }

    /// @dev The ticket's slot: the hash of the inputs a module is about to act on. Content-keyed on
    ///      purpose — a ticket is worthless to anyone holding different values.
    function _key(BundleInputs calldata inputs) internal pure returns (bytes32) {
        return keccak256(abi.encode(inputs));
    }

    function _ticket(bytes32 key) internal view returns (bool set) {
        assembly ("memory-safe") {
            set := tload(key)
        }
    }

    /// @dev Split the blob into the trailing public inputs and the proof body. A malformed length
    ///      returns empty pubs, which fails every check above — never reverts.
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

    /// @dev The served token's `decimals()`. Fail-closed read: any revert, missing code or short
    ///      return decodes to a sentinel no proof can name (the circuit bounds decimals below 32).
    function _decimalsOf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(DECIMALS_SELECTOR));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    /// @dev Call the generated verifier. `verify` is `view`: staticcall, so the adapter cannot even
    ///      be tricked into a state change; any revert or short/odd return is `false`.
    function _verify(address verifier, bytes calldata honkProof, bytes32[] memory pubs) internal view returns (bool) {
        (bool ok, bytes memory ret) = verifier.staticcall(abi.encodeWithSelector(VERIFY_SELECTOR, honkProof, pubs));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
