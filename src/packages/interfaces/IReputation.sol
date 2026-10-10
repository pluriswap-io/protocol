// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPassport} from "./IPassport.sol";

/// @dev Kernel verbs `admit` / `invoice*` / `notifyTerminal`.
interface IReputation {
    enum Close {
        Peaceful,
        Silent,
        Stalemate,
        ArbWin,
        ArbLoss,
        Deadlock, // a dispute in a deal with no tribunal, left to its clock by both sides
        NoShow // a Provider who let the fiat clock run out, or cancelled on his own (Anexo R, 2026-09-28)
    }

    function packageId() external view returns (bytes32);
    function passport() external view returns (IPassport);
    function feeRecipient() external view returns (address);
    /// @dev The fee policy is a share of the principal (Anexo R, 2026-09-28): activation from the Holder on
    ///      top of the principal, completion out of the pot. Basis points; the kernel does the arithmetic on
    ///      the principal the parties signed, with the values it bound to the signed `packageId` at activation
    ///      and copied into the deal (`PackagePrices`): it never reads them again for that deal.
    function activationBps() external view returns (uint256);
    function completionBps() external view returns (uint256);
    function contestBps() external view returns (uint256);
    function contestFloor() external view returns (uint256);
    function invoiceActivation(uint256 principal) external view returns (uint256 amount, address recipient);
    function invoiceCompletion(uint256 principal) external view returns (uint256 amount, address recipient);
    function invoiceContest(uint256 principal) external view returns (uint256 amount, address recipient);
    /// @dev `dealId` lets a module key its own state per deal — the private module uses it to check
    ///      that the two sides of one activation agreed on the same counterparty (§E.3.14.7 anti-farming).
    ///      `data` is the side's opaque package data, forwarded by the kernel from the activation.
    function admit(address wallet, bytes32 dealId, address token, uint256 principal, address vault, bytes calldata data)
        external
        returns (bytes32 subject);
    /// @dev `subject` is the Core snapshot (`IEscrow.subjects`), not a live `identify`; `counterparty`
    ///      is the other side's snapshot. Reputation that measures counterparties has to know who the
    ///      counterparty WAS: credit is once per pair, penalties are every time (§E.3.14.7).
    function notifyTerminal(bytes32 subject, bytes32 counterparty, address token, uint256 principal, Close kind)
        external;
}
