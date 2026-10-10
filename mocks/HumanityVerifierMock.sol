// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHumanityVerifier} from "../src/packages/interfaces/IHumanityVerifier.sol";

/// @dev Stand-in for the humanity circuit. Proof is abi.encode(bool ok). NOT A PROOF:
///      a passing mock says nothing about privacy or sybil resistance.
contract HumanityVerifierMock is IHumanityVerifier {
    function verifyHumanity(bytes calldata proof, bytes32) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
