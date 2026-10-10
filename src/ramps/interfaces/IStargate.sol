// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal Stargate V2 / OFT surface the ramp calls. Not the full vendor ABI.
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct OFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

struct OFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct Ticket {
    uint72 ticketId;
    bytes passengerBytes;
}

interface IStargate {
    function token() external view returns (address);

    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory);

    function quoteSend(SendParam calldata sendParam, bool payInLzToken) external view returns (MessagingFee memory);

    function sendToken(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory);
}
