// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Clocks {
    error TooEarly();
    error TooLate();

    function requireDue(uint256 origin, uint256 duration) public view {
        if (block.timestamp < origin + duration) revert TooEarly();
    }

    function requireStrictlyBefore(uint256 origin, uint256 duration) public view {
        if (block.timestamp >= origin + duration) revert TooLate();
    }
}
