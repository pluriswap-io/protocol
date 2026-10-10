// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Chain ids the deploy scripts branch on. Shared base so pickers can be mixed into one script.
abstract contract ChainIds is Script {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant ANVIL = 31337;

    /// @dev The `mocks/` stand-ins are lab tools with no authorisation: `PassportMock.setHuman` lets anyone claim
    ///      any subject (so `BondVault.withdraw` then pays them), `PaymentVerifierMock.verify` believes any blob naming the right claim, and
    ///      `ArbitrationMock.submitRuling` lets anyone render any verdict. Their package ids are signed exactly
    ///      like real ones, so a mock that reaches a value-bearing chain is a drain, not a stub. Adding a chain
    ///      here is a deliberate act; the default is refusal.
    function _requireMockChain(string memory what) internal view {
        require(
            block.chainid == ARBITRUM_SEPOLIA || block.chainid == ANVIL,
            string.concat(what, ": mock package refused on this chainId")
        );
    }
}
