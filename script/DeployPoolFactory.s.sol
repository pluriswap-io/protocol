// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";

contract DeployPoolFactory is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 pk = _key();
        address escrow = _escrow();
        vm.startBroadcast(pk);
        PoolFactory factory = new PoolFactory(address(escrow));
        vm.stopBroadcast();

        console.log("chainId", block.chainid);
        console.log("factory", address(factory));
        console.log("implementation", factory.implementation());
        console.log("officialCodehash");
        console.logBytes32(factory.officialCodehash());

        string memory obj = "poolFactory";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "factory", address(factory));
        vm.serializeAddress(obj, "escrow", escrow);
        vm.serializeAddress(obj, "implementation", factory.implementation());
        string memory json = vm.serializeBytes32(obj, "officialCodehash", factory.officialCodehash());
        vm.writeJson(json, _path());
        console.log("wrote", _path());
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-pool-factory.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-pool-factory.json");
    }

    /// @dev The escrow every pool of this factory points at: `ESCROW`, else the packaged stack's (the one the
    ///      official packages run on), else the core one.
    function _escrow() internal view returns (address escrow) {
        escrow = vm.envOr("ESCROW", address(0));
        if (escrow != address(0)) return escrow;
        string memory tag = block.chainid == ARBITRUM_SEPOLIA ? "sepolia" : vm.toString(block.chainid);
        string memory packages = string.concat("deployments/", tag, "-packages.json");
        string memory core = string.concat("deployments/", tag, ".json");
        escrow = vm.readFile(vm.exists(packages) ? packages : core).readAddress(".escrow");
        require(escrow.code.length > 0, "escrow has no code on this chain");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
