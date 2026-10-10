// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymentVerifier} from "./IPaymentVerifier.sol";

/// @dev Kernel verb `verifyProof`. The rail's verifier sits behind `verifier()`.
interface IPaymentProof {
    function packageId() external view returns (bytes32);
    function verifier() external view returns (IPaymentVerifier);
    function feeRecipient() external view returns (address);
    function verifyFee() external view returns (uint256);
    function invoiceVerify() external view returns (uint256 amount, address recipient);
    function verifyProof(bytes32 dealId, bytes calldata proof) external returns (bytes32 paymentNullifier);
}
