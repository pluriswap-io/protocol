// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Stargate V2 USDC on Arbitrum Sepolia. Not Circle's other test USDC.
library StargateSepolia {
    address internal constant USDC_POOL = 0x543BdA7c6cA4384FE90B1F5929bb851F52888983;
    address internal constant USDC = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;
    uint32 internal constant EID = 40231;
    uint32 internal constant ETHEREUM_SEPOLIA_EID = 40161;
}
