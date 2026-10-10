// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";

contract Deploy is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    /// @dev The official kernel shares (Anexo R, 2026-10-02): 0.3% at activation, 0.3% at completion, to the
    ///      DAO's receiving contract. `FEE_RECIPIENT` names it; the placeholder is for test chains only.
    uint16 internal constant ACT_BPS = 30;
    uint16 internal constant COMP_BPS = 30;

    function run() external {
        address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0xFEE));
        vm.startBroadcast();
        TestToken token = new TestToken();
        Escrow escrow = new Escrow(feeRecipient, ACT_BPS, COMP_BPS);
        vm.stopBroadcast();

        console.log("chainId", block.chainid);
        console.log("TestToken", address(token));
        console.log("Escrow", address(escrow));

        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        string memory json = vm.serializeAddress(obj, "escrow", address(escrow));
        string memory path = _path();
        vm.writeJson(json, path);
        console.log("wrote", path);
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia.json";
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }
}
