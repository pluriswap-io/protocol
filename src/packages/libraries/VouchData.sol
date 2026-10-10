// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBundleVerifier} from "../interfaces/IBundleVerifier.sol";

/// @title VouchData
/// @notice The envelope of a pool's side in `PackageData` when a human vouches for the Provider across from it
///         (PROTOCOLO.md Anexo R, 2026-09-29): `abi.encode(TAG, VouchInputs, proof)`.
/// @dev The passport, the reputation and the court all receive the same side's data, and the court cannot ask
///      whether the Holder is a pool, so the envelope says it. The tag is `2^256 − 1`, above the BN254 modulus:
///      a person's side opens with its `dealSubject`, a field element — no `prepare_side` ticket can exist for a
///      subject this large — so the two shapes cannot be mistaken for each other.
library VouchData {
    bytes32 internal constant TAG = bytes32(type(uint256).max);

    function isVouch(bytes calldata data) internal pure returns (bool) {
        return data.length >= 32 && bytes32(data[0:32]) == TAG;
    }

    function decode(bytes calldata data)
        internal
        pure
        returns (IBundleVerifier.VouchInputs memory inputs, bytes memory proof)
    {
        (, inputs, proof) = abi.decode(data, (bytes32, IBundleVerifier.VouchInputs, bytes));
    }

    function encode(IBundleVerifier.VouchInputs memory inputs, bytes memory proof)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(TAG, inputs, proof);
    }
}
