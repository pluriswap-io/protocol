// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @dev Mints TUSD (6 decimals) to a wallet. Default 1_000_000 = 1 TUSD.
/// TO=0x... [AMOUNT=1000000] forge script script/Mint.s.sol --rpc-url arbitrum_sepolia --broadcast --sender <holder>
contract Mint is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant DEFAULT_AMOUNT = 1_000_000;

    function run() external {
        address to = vm.envAddress("TO");
        require(to != address(0), "TO");
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);

        TestToken token = _token();
        uint256 pk = _key();

        vm.startBroadcast(pk);
        token.mint(to, amount);
        vm.stopBroadcast();

        console.log("testToken", address(token));
        console.log("to", to);
        console.log("minted", amount);
        console.log("balance", token.balanceOf(to));
    }

    function _token() internal view returns (TestToken token) {
        address override_ = vm.envOr("TOKEN", address(0));
        if (override_ != address(0)) return TestToken(override_);
        string memory path = _path();
        require(vm.exists(path), path);
        token = TestToken(vm.readFile(path).readAddress(".testToken"));
        require(address(token).code.length > 0, "token");
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-paths.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-paths.json");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
