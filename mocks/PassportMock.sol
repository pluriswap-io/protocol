// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";

/// @dev Sepolia adapter: wallet → subject. Official decoder is not on Arbitrum Sepolia.
contract PassportMock is IPassport {
    bytes32 public immutable packageId;
    mapping(address wallet => bytes32 subject) public subjectOf;

    constructor() {
        packageId = PackageId.passport(address(this));
    }

    function setHuman(address wallet, bytes32 subject) external {
        subjectOf[wallet] = subject;
    }

    function identify(address wallet, address, bytes32, bytes calldata) external view returns (bytes32 subject) {
        subject = subjectOf[wallet];
        if (subject == bytes32(0)) revert NoPassport();
    }
}
