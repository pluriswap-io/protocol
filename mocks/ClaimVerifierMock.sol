// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClaimVerifier} from "../src/packages/interfaces/IClaimVerifier.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";

/// @dev Stand-in for the claim circuit. Proof is abi.encode(bool ok). NOT A PROOF: a passing mock
///      says nothing about the dealSubject <-> dealId binding or the delta arithmetic.
contract ClaimVerifierMock is IClaimVerifier {
    function verifyClaim(
        bytes32,
        bytes32,
        bytes32,
        bytes32,
        IReputation.Close,
        address,
        uint256,
        bytes32,
        bytes32,
        uint256,
        bool,
        bytes calldata proof
    ) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
