// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";

/// @title PrivateRegister
/// @notice Registers the sample account of the fixtures against a deployed private layer, with the
///         committed proofs — the first time the private layer runs on a chain rather than in a test.
/// @dev `DeployPrivate` puts the stack down and the doctor checks its wiring, but nothing had ever
///      put a leaf in the accounts tree outside `forge test`. That left the layer verifiable and
///      unobserved: no chain anywhere had a real private account on it.
///
///      This works because the committed proofs are pinned to the canonical `registryId`, which is
///      what `DeployPrivate` defaults to. Two constraints follow and both are load-bearing:
///      the enrolled identity commitment must be the fixture's (the humanity proof witnesses ITS
///      membership), and it must be the FIRST enrollment (the witness is against that tree state).
///      So this runs once per deployment, right after it, or not at all.
///
///      What it leaves behind is a tree with a leaf in it, which is what a prover needs to read.
///
///      Usage: `forge script script/PrivateRegister.s.sol:PrivateRegister --rpc-url $RPC --broadcast`
contract PrivateRegister is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        string memory json = vm.readFile(_path());
        string memory vectors = vm.readFile("test/fixtures/vectors.json");

        HumanityRegistry registry = HumanityRegistry(json.readAddress(".humanityRegistry"));
        PrivatePassport passport = PrivatePassport(json.readAddress(".privatePassport"));
        PrivateReputation rep = PrivateReputation(json.readAddress(".privateReputation"));
        PoseidonTree accountTree = PoseidonTree(json.readAddress(".accountTree"));
        PassportDecoderMock decoder = PassportDecoderMock(json.readAddress(".passportDecoder"));

        bytes32 hn = bytes32(vectors.readUint(".registry.sample_hn"));
        bytes32 leaf0 = bytes32(vectors.readUint(".registry.sample_leaf0"));
        bytes32 hsk = bytes32(vectors.readUint(".registry.hsk"));

        if (rep.registeredHn(hn)) {
            console.log("already registered on this deployment; nothing to do");
            return;
        }

        uint256 pk = _key();
        address anchor = vm.addr(pk);
        bytes32 commitment = registry.identityCommitmentOf(hsk);

        vm.startBroadcast(pk);
        // The anchor is the one place the private layer is necessarily public: enrolling IS the
        // decoder's score gate. Everything after this point is hsk-side.
        if (!registry.isHuman(anchor)) {
            decoder.setScore(anchor, 200_000, uint64(block.timestamp + 30 days));
        }
        if (!registry.enrolled(anchor)) {
            registry.enroll(commitment);
        }
        // The bundle of §E.3.15.3: humanity first, then the account leaf under the same `hn`.
        passport.register(_proof("register_humanity"), hn);
        rep.register(_proof("register_account"), hn, leaf0);
        vm.stopBroadcast();

        require(passport.humanitySpent(hn), "humanity not burned");
        require(rep.registeredHn(hn), "account not registered");
        require(accountTree.nextIndex() == 1, "leaf0 not inserted");
        require(accountTree.isKnownRoot(accountTree.root()), "root not live");

        console.log("registered the sample account with real proofs");
        console.log("  accountTree", address(accountTree));
        console.log("  leaves", accountTree.nextIndex());
        console.log("  root");
        console.logBytes32(accountTree.root());
    }

    function _proof(string memory circuit) internal view returns (bytes memory) {
        return
            vm.readFile(string.concat("test/fixtures/proofs/", circuit, ".json")).readBytes(".proof_with_public_inputs");
    }

    function _path() internal view returns (string memory) {
        return block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-private.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-private.json");
    }

    function _key() internal view returns (uint256) {
        if (block.chainid == 31337) return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        return vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
