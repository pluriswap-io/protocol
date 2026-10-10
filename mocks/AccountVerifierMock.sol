// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccountVerifier} from "../src/packages/interfaces/IAccountVerifier.sol";

/// @dev Stand-in for the account circuits. Proof is abi.encode(bool ok). NOT A PROOF:
///      a passing mock says nothing about privacy or account binding.
contract AccountVerifierMock is IAccountVerifier {
    function verifyAccount(bytes calldata proof, bytes32, bytes32) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }

    function verifyOpenAccount(bytes calldata proof, bytes32) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }

    function verifyUpgrade(bytes calldata proof, bytes32, bytes32, bytes32, bytes32) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
