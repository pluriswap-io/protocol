// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDepositVerifier} from "../src/packages/interfaces/IDepositVerifier.sol";

/// @dev Mock behind the frozen `IDepositVerifier`: decodes the proof as the verdict. A passing
///      mock is not a proof.
contract DepositVerifierMock is IDepositVerifier {
    function verifyDeposit(address, uint256, bytes32, bytes calldata proof) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
