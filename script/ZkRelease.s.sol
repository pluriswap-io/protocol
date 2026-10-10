// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Status} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {PaymentProof} from "../src/packages/PaymentProof.sol";
import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @dev CASE-PAY-01 on chain: the ZK deal `CatalogDeals` left FUNDED, released by a proof of its signed
///      payment. A separate run because the claim names the deal's ACTIVATION CLOCK, which exists only
///      once the activation is mined — the order a real Provider follows too (pay after funding, prove
///      after paying). The verifier behind the module is `PaymentVerifierMock` (test chains only): the
///      blob is the claim itself, read here from the chain exactly as `PaymentProof` will build it.
contract ZkRelease is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        string memory catalog = vm.readFile(_path());
        Escrow escrow = Escrow(catalog.readAddress(".escrow"));
        PaymentProof zk = PaymentProof(catalog.readAddress(".zk"));
        TestToken token = TestToken(catalog.readAddress(".testToken"));
        bytes32 id = catalog.readBytes32(".zkDealId");
        require(escrow.status(id) == Status.FUNDED, "zk deal not funded");

        bytes32 nullifier = keccak256(abi.encode("zk-release-receipt", id));
        bytes memory proof = abi.encode(
            IPaymentVerifier.PaymentClaim({
                dealId: id,
                fiatCommit: escrow.terms(id).fiatCommit,
                notBefore: uint64(escrow.clocks(id).activatedAt),
                holder: escrow.terms(id).holder
            }),
            nullifier
        );
        (uint256 fee, address feeRecipient) = zk.invoiceVerify();
        uint256 feesBefore = token.balanceOf(feeRecipient);

        vm.startBroadcast(_relayerKey());
        escrow.verifyProof(id, proof);
        vm.stopBroadcast();

        require(escrow.status(id) == Status.RELEASED, "zk released");
        require(zk.used(nullifier), "nullifier spent");
        require(token.balanceOf(feeRecipient) >= feesBefore + fee, "zk fee");
        console.log("zkDeal", vm.toString(id));
        console.log("zkStatus", uint256(escrow.status(id)));
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    /// @dev `verifyProof` is permissionless: whoever carries the proof. Here, the Holder's key.
    function _relayerKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
