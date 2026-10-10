// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPrivateReputation} from "../src/packages/interfaces/IPrivateReputation.sol";

/// @dev Stand-in for `PrivateReputation.claimed`: the vault's reabsorb gating, flippable by hand.
///      In the deal suites the real module plays this role end-to-end (claim -> reabsorb).
contract GatingMock is IPrivateReputation {
    mapping(bytes32 => bool) public claimed;

    function setClaimed(bytes32 subject) external {
        claimed[subject] = true;
    }
}
