// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, PackageMods, PackagePrices, DealClocks} from "../libraries/Types.sol";

/// @dev Read surface of the recinto. Packages, pools, and ramps import this.
///      Nobody writes deal state or moves principal through this interface.
interface IEscrow {
    function domainSeparator() external view returns (bytes32);

    function used(address signer, uint256 nonce) external view returns (bool);

    function dealOf(address signer, uint256 nonce) external view returns (bytes32);

    function status(bytes32 dealId) external view returns (Status);

    function terms(bytes32 dealId) external view returns (DealTerms memory);

    function clocks(bytes32 dealId) external view returns (DealClocks memory);

    function subjects(bytes32 dealId) external view returns (bytes32 holderSubject, bytes32 providerSubject);

    function modules(bytes32 dealId) external view returns (PackageMods memory);

    function kinds(bytes32 dealId) external view returns (uint8);

    /// @dev The package prices the deal was activated under: what the kernel charges it, whatever the packages
    ///      charge the deals that come after.
    function pricesOf(bytes32 dealId) external view returns (PackagePrices memory);

    function settlementOf(bytes32 dealId) external view returns (Status status_, uint256 holderAmt, uint256 providerAmt);

    function creditOf(address token, address beneficiary) external view returns (uint256);

    function contestPaid(bytes32 dealId) external view returns (bool);

    /// @dev The kernel's own fee (immutable): who receives it, and its share of the principal at activation
    ///      (from the Holder, on top of the principal) and at completion (out of the pot).
    function feeRecipient() external view returns (address);

    function activationBps() external view returns (uint16);

    function completionBps() external view returns (uint16);

    /// @dev Kernel fees accrued in `token` and not yet swept to `feeRecipient`.
    function feesOwed(address token) external view returns (uint256);

    /// @dev The post-terminal package calls a closed deal still owes (bit per call); zero once delivered.
    function postPending(bytes32 dealId) external view returns (uint8);
}
