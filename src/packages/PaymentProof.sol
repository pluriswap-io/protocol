// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Governed} from "./Governed.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {DealTerms} from "../libraries/Types.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";
import {IPaymentProof} from "./interfaces/IPaymentProof.sol";
import {IPaymentVerifier} from "./interfaces/IPaymentVerifier.sol";

/// @title PaymentProof
/// @notice The `PAYMENT_PROOF` package (PROTOCOLO.md §E.3.12.1): a deal that selected it ends in a proof
///         of the signed payment or in a timeout. No dispute, no tribunal, no 50/50.
///
/// @dev Rail-agnostic. This contract is what every payment rail shares — the claim, the nullifier, the
///      fee — and the rail itself is the `IPaymentVerifier` named in the `packageId`. Another rail, or
///      the same rail with another trust anchor, is another verifier and therefore another package.
///
///      The claim is the KERNEL's, never the caller's: the deal id the kernel passes, the `fiatCommit`
///      both parties signed, and the activation clock as the earliest a payment may be. The caller
///      only brings the proof. So a proof of a real payment that is not the agreed one — another
///      amount, another account, an old transfer between the same two people — opens another claim,
///      and the adapter says no.
///
///      Custody never passes through here. The kernel charges `verifyFee` and commits `RELEASED` in the
///      same transaction as this call; if anything here reverts, the deal is exactly as it was.
contract PaymentProof is IPaymentProof, Governed {
    error Unauthorized();
    error ZeroAddress();
    error InvalidProof();
    error NullifierUsed();
    error FiatCommitNotInField();

    /// @notice One fiat payment settled one deal.
    event PaymentProven(bytes32 indexed dealId, bytes32 indexed paymentNullifier);

    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    address public immutable escrow;
    IPaymentVerifier public immutable verifier;
    address public immutable feeRecipient;
    /// @dev The price of a proof (Anexo R, 2026-10-06): what the DAO may change, up to `MAX_VERIFY_FEE`, for the deals
    ///      not yet activated. The kernel copies it at activation and charges a live deal that one. The verifier is
    ///      not governed: which payments count is a new adapter, never a vote.
    uint256 public verifyFee;
    /// @dev Five whole tokens of a six-decimal stablecoin, in raw units of the deal's token.
    uint256 public constant MAX_VERIFY_FEE = 5_000_000;

    /// @notice Spent payments. A payment settles at most one deal under this verifier, forever.
    mapping(bytes32 paymentNullifier => bool) public used;

    constructor(
        address escrow_,
        IPaymentVerifier verifier_,
        address feeRecipient_,
        uint256 verifyFee_,
        address governor_
    ) Governed(governor_) {
        if (escrow_ == address(0) || address(verifier_) == address(0)) revert ZeroAddress();
        if (governor_ != address(0) && verifyFee_ > MAX_VERIFY_FEE) revert OutOfBounds();
        escrow = escrow_;
        verifier = verifier_;
        feeRecipient = feeRecipient_;
        verifyFee = verifyFee_;
    }

    /// @inheritdoc IPaymentProof
    /// @dev The fee in force: it moves when the DAO enacts a new one.
    function packageId() public view returns (bytes32) {
        return PackageId.zk(address(this), address(verifier), feeRecipient, verifyFee);
    }

    function pendingVerifyFee() external view returns (uint256 fee) {
        if (pendingAt != 0) fee = abi.decode(_pendingPolicy, (uint256));
    }

    /// @notice The DAO proposes the price of a proof for the deals activated once it is enacted.
    function proposePolicy(uint256 fee) external {
        if (fee > MAX_VERIFY_FEE) revert OutOfBounds();
        _propose(abi.encode(fee));
    }

    function _enact(bytes memory encoded) internal override {
        verifyFee = abi.decode(encoded, (uint256));
    }

    function invoiceVerify() external view returns (uint256 amount, address recipient) {
        return (verifyFee, feeRecipient);
    }

    /// @dev Only the kernel: a direct caller could burn a real payment's nullifier without releasing
    ///      anything, and the Provider could never use that payment again.
    function verifyProof(bytes32 dealId, bytes calldata proof) external returns (bytes32 paymentNullifier) {
        if (msg.sender != escrow) revert Unauthorized();
        DealTerms memory t = IEscrow(escrow).terms(dealId);
        bytes32 fiatCommit = t.fiatCommit;
        // Not a Poseidon output, so no circuit can take it and no proof will ever open it. The kernel
        // cannot know (the field is the rail's), so the deal can only time out — say so in words.
        if (uint256(fiatCommit) >= BN254_P) revert FiatCommitNotInField();

        IPaymentVerifier.PaymentClaim memory claim = IPaymentVerifier.PaymentClaim({
            dealId: dealId,
            fiatCommit: fiatCommit,
            notBefore: uint64(IEscrow(escrow).clocks(dealId).activatedAt),
            holder: t.holder
        });
        bool ok;
        (ok, paymentNullifier) = verifier.verify(claim, proof);
        if (!ok) revert InvalidProof();
        if (used[paymentNullifier]) revert NullifierUsed();
        used[paymentNullifier] = true;
        emit PaymentProven(dealId, paymentNullifier);
    }
}
