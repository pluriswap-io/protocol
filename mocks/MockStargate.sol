// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IStargate,
    SendParam,
    MessagingFee,
    OFTLimit,
    OFTFeeDetail,
    OFTReceipt,
    MessagingReceipt,
    Ticket
} from "../src/ramps/interfaces/IStargate.sol";

/// @dev Isolated Stargate V2 pool stand-in. Haircut and nativeFee are infra.
contract MockStargate is IStargate {
    using SafeERC20 for IERC20;

    error InsufficientNativeFee();

    address public immutable token;
    uint256 public immutable nativeFee;
    uint256 public immutable haircut;

    constructor(address token_, uint256 nativeFee_, uint256 haircut_) {
        token = token_;
        nativeFee = nativeFee_;
        haircut = haircut_;
    }

    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory limit, OFTFeeDetail[] memory details, OFTReceipt memory receipt)
    {
        limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
        details = new OFTFeeDetail[](0);
        receipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: sendParam.amountLD - haircut});
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function sendToken(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory receipt, Ticket memory)
    {
        if (msg.value < fee.nativeFee) revert InsufficientNativeFee();
        IERC20(token).safeTransferFrom(msg.sender, address(this), sendParam.amountLD);
        address to = address(uint160(uint256(sendParam.to)));
        uint256 out = sendParam.amountLD - haircut;
        IERC20(token).safeTransfer(to, out);
        if (msg.value > fee.nativeFee) {
            (bool ok,) = refundAddress.call{value: msg.value - fee.nativeFee}("");
            require(ok);
        }
        receipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: out});
    }
}
