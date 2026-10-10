// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPassport} from "../src/packages/interfaces/IPassport.sol";

/// @dev A passport whose decoder is dead: `identify` always reverts, like a passport whose
///      third-party proxy went down. The private vault holds one as its peer in the vault suites,
///      and every deposit, reserve, reabsorb and withdraw still works: the proof replaces the
///      identification (PROTOCOLO.md §E.3.15.6), so the vault has no liveness dependency on any
///      decoder.
contract DeadPassportMock is IPassport {
    function identify(address, address, bytes32, bytes calldata) external pure returns (bytes32) {
        revert NoPassport();
    }

    function packageId() external pure returns (bytes32) {
        return keccak256("dead-passport");
    }
}
