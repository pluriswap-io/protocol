// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {ICourt} from "../src/packages/interfaces/ICourt.sol";
import {Settlement} from "../src/libraries/Settlement.sol";
import {DealTerms} from "../src/libraries/Types.sol";

contract ArbitrationMock is ICourt {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error ZeroAddress();
    error AlreadyOpen();
    error NotOpen();
    error InvalidRuling();
    error DeadlineNotDue();

    enum Ruling {
        None,
        HolderWin,
        ProviderWin,
        Stalemate
    }

    address public immutable tribunal;
    address public immutable feeToken;
    address public immutable operator;
    uint256 public immutable courtFee;
    uint256 public immutable duration;
    uint256 public immutable contestFee;
    address public immutable feeRecipient;
    uint256 public immutable activationBps;
    /// @dev Mutable on purpose: a test sets it before signing, or after to model a court that drifted.
    uint256 public bondShareBps;

    mapping(bytes32 dealId => address controller) public controllerOf;
    mapping(bytes32 dealId => uint256 openedAt) public openedAt;
    mapping(bytes32 dealId => Ruling ruling) public rulingOf;

    constructor(
        address tribunal_,
        address feeToken_,
        uint256 courtFee_,
        uint256 duration_,
        address operator_,
        uint256 contestFee_,
        address feeRecipient_,
        uint256 activationBps_
    ) {
        // Same guard as the real adapter: a priced contest with no recipient bricks `openDisputed`.
        if (contestFee_ != 0 && feeRecipient_ == address(0)) revert ZeroAddress();
        tribunal = tribunal_;
        feeToken = feeToken_;
        courtFee = courtFee_;
        duration = duration_;
        operator = operator_;
        contestFee = contestFee_;
        feeRecipient = feeRecipient_;
        activationBps = activationBps_;
    }

    function setBondShareBps(uint256 bps) external {
        bondShareBps = bps;
    }

    function packageId() external view returns (bytes32) {
        return PackageId.arbitration(address(this), tribunal, courtFee, contestFee, feeRecipient, activationBps, bondShareBps);
    }

    function packageBinding() external view returns (address partner, uint256 key) {
        return (tribunal, courtFee);
    }

    function open(bytes32 dealId, address controller) external {
        if (msg.sender != controller) revert Unauthorized();
        _open(dealId, controller);
    }

    /// @dev A mock court is always there to be escalated to; override to model one that is not.
    function available(bytes32) external view virtual returns (bool) {
        return true;
    }

    /// @dev A mock court takes any deal and needs nothing to know about it.
    function bind(bytes32, DealTerms calldata, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        virtual
    {
        if (operator == address(0) || msg.sender != operator) revert Unauthorized();
    }

    function openCourt(bytes32 dealId, address controller) external payable {
        if (operator == address(0) || msg.sender != operator) revert Unauthorized();
        _open(dealId, controller);
    }

    function readRuling(bytes32 dealId) external view returns (uint8) {
        return uint8(rulingOf[dealId]);
    }

    function _open(bytes32 dealId, address controller) internal {
        if (controllerOf[dealId] != address(0)) revert AlreadyOpen();
        Settlement.pullExact(feeToken, controller, courtFee);
        IERC20(feeToken).safeTransfer(tribunal, courtFee);
        controllerOf[dealId] = controller;
        openedAt[dealId] = block.timestamp;
    }

    function submitRuling(bytes32 dealId, Ruling ruling) external {
        if (controllerOf[dealId] == address(0)) revert NotOpen();
        if (rulingOf[dealId] != Ruling.None) revert AlreadyOpen();
        if (ruling == Ruling.None) revert InvalidRuling();
        rulingOf[dealId] = ruling;
    }

    function forceTimeout(bytes32 dealId) external {
        if (controllerOf[dealId] == address(0)) revert NotOpen();
        if (rulingOf[dealId] != Ruling.None) revert AlreadyOpen();
        if (block.timestamp < openedAt[dealId] + duration) revert DeadlineNotDue();
        rulingOf[dealId] = Ruling.Stalemate;
    }
}
