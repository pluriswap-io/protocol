// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";

/// @dev The real bundle verifier, plus ONE side it is told to believe: the counterparty of the committed
///      sample deal. An activation admits both sides and inserts both leaves together (Anexo R, 2026-09-29),
///      so a real-proof suite needs a second side to reach the roots its committed claim and withdraw proofs
///      witness — and the fixture set carries one real side, not two. Everything about the sample side still
///      goes through the real adapter and the committed proof; only the counterparty is taken on trust, and
///      it is named so here rather than hidden in a mock.
contract CounterpartyBundle is IBundleVerifier {
    IBundleVerifier public immutable real;
    mapping(bytes32 key => bool) public trusted;

    constructor(IBundleVerifier real_) {
        real = real_;
    }

    function trust(BundleInputs calldata inputs) external {
        trusted[keccak256(abi.encode(inputs))] = true;
    }

    function verify(BundleInputs calldata inputs, bytes calldata proof) external returns (bool) {
        if (trusted[keccak256(abi.encode(inputs))]) return true;
        return real.verify(inputs, proof);
    }

    function wasProven(BundleInputs calldata inputs) external view returns (bool) {
        return trusted[keccak256(abi.encode(inputs))] || real.wasProven(inputs);
    }

    function verifyVouch(VouchInputs calldata inputs, bytes calldata proof) external returns (bool) {
        return real.verifyVouch(inputs, proof);
    }

    function wasVouched(VouchInputs calldata inputs) external view returns (bool) {
        return real.wasVouched(inputs);
    }
}
