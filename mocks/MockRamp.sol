// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RampIntent, RampQuote, IRamp} from "../src/ramps/interfaces/IRamp.sol";

/// @dev Same-chain stand-in for IRamp. Haircut (if any) is infra, never kept here.
contract MockRamp is IRamp {
    using SafeERC20 for IERC20;

    error TokenMismatch();
    error InsufficientNativeFee();
    error InsufficientAmountOut();

    address public immutable token;
    address public immutable infra;
    uint256 public immutable nativeFee;
    uint256 public immutable infraBps;

    constructor(address token_, uint256 nativeFee_, uint256 infraBps_) {
        token = token_;
        nativeFee = nativeFee_;
        infraBps = infraBps_;
        infra = address(0xFEE);
    }

    function quote(RampIntent calldata intent) external view returns (RampQuote memory q) {
        if (intent.token != token) revert TokenMismatch();
        q.nativeFee = nativeFee;
        q.amountOut = _out(intent.amount);
    }

    function send(RampIntent calldata intent) external payable {
        if (intent.token != token) revert TokenMismatch();
        if (msg.value < nativeFee) revert InsufficientNativeFee();
        uint256 out = _out(intent.amount);
        if (out < intent.minAmountOut) revert InsufficientAmountOut();

        IERC20(token).safeTransferFrom(msg.sender, address(this), intent.amount);
        IERC20(token).safeTransfer(intent.to, out);
        uint256 cut = intent.amount - out;
        if (cut > 0) IERC20(token).safeTransfer(infra, cut);
        if (nativeFee > 0) {
            (bool paid,) = infra.call{value: nativeFee}("");
            require(paid);
        }

        _refund(intent.refund, msg.value - nativeFee);
    }

    function _out(uint256 amount) internal view returns (uint256) {
        return amount - (amount * infraBps / 10_000);
    }

    function _refund(address to, uint256 amount) internal {
        if (amount == 0) return;
        address dest = to == address(0) ? msg.sender : to;
        (bool ok,) = dest.call{value: amount}("");
        require(ok);
    }
}
