// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "../src/libraries/PackageId.sol";
import {ICourt} from "../src/packages/interfaces/ICourt.sol";
import {DealTerms} from "../src/libraries/Types.sol";

/// @dev A court paid in the chain's coin when it opens, the shape the kernel's payable `openCourt` exists for:
///      the opener sends exactly `cost` and the court keeps it. Kernel-only like a real adapter; tests call
///      `giveRuling` and never wait on anyone. The ruling it takes is the external one — 0 refuses (a
///      stalemate), 1 the Holder, 2 the Provider — so a refusal is a ruling, not silence.
contract EthCourtMock is ICourt {
    error Unauthorized();
    error ZeroAddress();
    error AlreadyOpen();
    error NotOpen();
    error AlreadyRuled();
    error InvalidRuling();
    error WrongFee();

    enum Ruling {
        None,
        HolderWin,
        ProviderWin,
        Stalemate
    }

    uint256 public immutable cost;
    address public immutable kernel;
    uint256 public immutable contestFee;
    address public immutable feeRecipient;
    /// @dev Mutable on purpose: a test sets it before signing, or after to model a court that drifted.
    uint256 public bondShareBps;
    uint256 public constant activationBps = 0;

    mapping(bytes32 dealId => bool) public opened;
    mapping(bytes32 dealId => Ruling) public rulingOf;

    constructor(uint256 cost_, address kernel_, uint256 contestFee_, address feeRecipient_) {
        if (kernel_ == address(0)) revert ZeroAddress();
        // A priced contest with no recipient bricks `openDisputed`.
        if (contestFee_ != 0 && feeRecipient_ == address(0)) revert ZeroAddress();
        cost = cost_;
        kernel = kernel_;
        contestFee = contestFee_;
        feeRecipient = feeRecipient_;
    }

    function setBondShareBps(uint256 bps) external {
        bondShareBps = bps;
    }

    function packageId() external view returns (bytes32) {
        return PackageId.arbitration(address(this), address(this), cost, contestFee, feeRecipient, 0, bondShareBps);
    }

    function packageBinding() external view returns (address partner, uint256 key) {
        return (address(this), cost);
    }

    function available(bytes32) external pure returns (bool) {
        return true;
    }

    function bind(bytes32, DealTerms calldata, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
    {
        if (msg.sender != kernel) revert Unauthorized();
    }

    function openCourt(bytes32 dealId, address) external payable {
        if (msg.sender != kernel) revert Unauthorized();
        if (opened[dealId]) revert AlreadyOpen();
        if (msg.value != cost) revert WrongFee();
        opened[dealId] = true;
    }

    function giveRuling(bytes32 dealId, uint256 ruling) external {
        if (!opened[dealId]) revert NotOpen();
        if (rulingOf[dealId] != Ruling.None) revert AlreadyRuled();
        if (ruling == 0) rulingOf[dealId] = Ruling.Stalemate;
        else if (ruling == 1) rulingOf[dealId] = Ruling.HolderWin;
        else if (ruling == 2) rulingOf[dealId] = Ruling.ProviderWin;
        else revert InvalidRuling();
    }

    function readRuling(bytes32 dealId) external view returns (uint8) {
        return uint8(rulingOf[dealId]);
    }
}
