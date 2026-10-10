// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RampIntent, RampQuote, IRamp} from "./interfaces/IRamp.sol";
import {IStargate, SendParam, MessagingFee, OFTReceipt} from "./interfaces/IStargate.sol";

/// @dev IRamp over a Stargate V2 pool. No compose, taxi only, zero protocol bps.
contract StargateV2Ramp is IRamp {
    using SafeERC20 for IERC20;

    error TokenMismatch();
    error InsufficientNativeFee();
    error InsufficientAmountOut();
    error RefundFailed();
    error ZeroAddress();

    IStargate public immutable stargate;
    address public immutable token;

    constructor(address stargate_) {
        if (stargate_ == address(0)) revert ZeroAddress();
        stargate = IStargate(stargate_);
        token = IStargate(stargate_).token();
        if (token == address(0)) revert ZeroAddress();
    }

    function quote(RampIntent calldata intent) external view returns (RampQuote memory q) {
        if (intent.token != token) revert TokenMismatch();
        SendParam memory p = _param(intent);
        (,, OFTReceipt memory receipt) = stargate.quoteOFT(p);
        p.minAmountLD = receipt.amountReceivedLD;
        MessagingFee memory fee = stargate.quoteSend(p, false);
        q.nativeFee = fee.nativeFee;
        q.amountOut = receipt.amountReceivedLD;
    }

    function send(RampIntent calldata intent) external payable {
        if (intent.token != token) revert TokenMismatch();
        SendParam memory p = _param(intent);
        (,, OFTReceipt memory receipt) = stargate.quoteOFT(p);
        if (receipt.amountReceivedLD < intent.minAmountOut) revert InsufficientAmountOut();
        p.minAmountLD = intent.minAmountOut;
        MessagingFee memory fee = stargate.quoteSend(p, false);
        if (msg.value < fee.nativeFee) revert InsufficientNativeFee();

        IERC20 erc = IERC20(token);
        erc.safeTransferFrom(msg.sender, address(this), intent.amount);
        erc.forceApprove(address(stargate), intent.amount);
        stargate.sendToken{value: fee.nativeFee}(p, fee, _refundTo(intent.refund));

        uint256 leftover = erc.balanceOf(address(this));
        if (leftover > 0) erc.safeTransfer(msg.sender, leftover);
        _pay(intent.refund, address(this).balance);
    }

    function _param(RampIntent calldata intent) internal pure returns (SendParam memory p) {
        p.dstEid = intent.dest;
        p.to = bytes32(uint256(uint160(intent.to)));
        p.amountLD = intent.amount;
        p.minAmountLD = intent.minAmountOut;
    }

    function _refundTo(address refund) internal view returns (address) {
        return refund == address(0) ? msg.sender : refund;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = _refundTo(to).call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    receive() external payable {}
}
