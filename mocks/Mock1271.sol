// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Mock1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bool public ok;

    function setOk(bool v) external {
        ok = v;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        return ok ? MAGIC : bytes4(0);
    }
}
