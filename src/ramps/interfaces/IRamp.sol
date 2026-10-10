// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Vendor-agnostic ramp. `dest` is opaque: Stargate uses a LayerZero eid.
///      No protocol bps. `nativeFee` is infrastructure only.
struct RampIntent {
    address token;
    uint256 amount;
    uint256 minAmountOut;
    uint32 dest;
    address to;
    address refund;
}

struct RampQuote {
    uint256 nativeFee;
    uint256 amountOut;
}

interface IRamp {
    function quote(RampIntent calldata intent) external view returns (RampQuote memory);
    function send(RampIntent calldata intent) external payable;
}
