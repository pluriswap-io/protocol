// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";

/// @dev The rail's verifier, mocked until a rail's circuit exists. It is not a proof: the blob is
///      `abi.encode(PaymentClaim named, bytes32 nullifier)` and the mock believes it. What it DOES
///      enforce is the one promise every real adapter makes — the proof must name exactly the claim the
///      module built — so the module's binding to the kernel (deal, signed payment, activation clock)
///      is exercised for real. Test chains only (`ChainIds._requireMockChain`).
contract PaymentVerifierMock is IPaymentVerifier {
    bool public answer = true;

    function setAnswer(bool a) external {
        answer = a;
    }

    function verify(PaymentClaim calldata claim, bytes calldata proof)
        external
        view
        returns (bool ok, bytes32 paymentNullifier)
    {
        (PaymentClaim memory named, bytes32 nullifier) = abi.decode(proof, (PaymentClaim, bytes32));
        ok = answer && keccak256(abi.encode(named)) == keccak256(abi.encode(claim));
        paymentNullifier = nullifier;
    }

    /// @dev A mock has no keys to rotate: it never sets.
    function sunset() external pure returns (uint64) {
        return type(uint64).max;
    }

    /// @dev The blob a proof of `claim` would be — what a test or a test-chain script submits.
    function proofFor(PaymentClaim memory claim, bytes32 nullifier) external pure returns (bytes memory) {
        return abi.encode(claim, nullifier);
    }
}
