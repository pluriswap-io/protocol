// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWithdrawVerifier} from "../src/packages/interfaces/IWithdrawVerifier.sol";

/// @dev Mock behind the frozen `IWithdrawVerifier`: decodes the proof as the verdict. A passing
///      mock is not a proof.
contract WithdrawVerifierMock is IWithdrawVerifier {
    function verifyWithdraw(address, address, uint256, bytes32, bytes32, bytes32, bytes calldata proof)
        external
        pure
        returns (bool)
    {
        return abi.decode(proof, (bool));
    }
}
