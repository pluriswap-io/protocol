// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @dev Two P2P deals: one RELEASED (markFiat + release), one CANCELLED (cancelByProvider).
contract Deal is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 holderPk;
        uint256 providerPk;
        (holderPk, providerPk) = _keys();
        address holder = vm.addr(holderPk);
        address provider = vm.addr(providerPk);

        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.005 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        (TestToken token, Escrow escrow) = _loadOrDeploy(holderPk);

        vm.startBroadcast(holderPk);
        token.mint(holder, PRINCIPAL * 2);
        token.approve(address(escrow), type(uint256).max);
        vm.stopBroadcast();

        bytes32 releasedId = _activate(escrow, token, holder, provider, holderPk, providerPk, 1, 1);
        vm.startBroadcast(providerPk);
        escrow.markFiat(releasedId);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.release(releasedId);
        vm.stopBroadcast();

        bytes32 cancelledId = _activate(escrow, token, holder, provider, holderPk, providerPk, 2, 2);
        vm.startBroadcast(providerPk);
        escrow.cancelByProvider(cancelledId);
        vm.stopBroadcast();

        require(escrow.status(releasedId) == Status.RELEASED, "released deal");
        require(escrow.status(cancelledId) == Status.CANCELLED, "cancelled deal");
        require(token.balanceOf(provider) == PRINCIPAL, "provider payout");
        require(token.balanceOf(holder) == PRINCIPAL, "holder refund");

        console.log("released", vm.toString(releasedId));
        console.log("cancelled", vm.toString(cancelledId));

        string memory obj = "deals";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        vm.serializeAddress(obj, "escrow", address(escrow));
        vm.serializeBytes32(obj, "releasedDealId", releasedId);
        string memory json = vm.serializeBytes32(obj, "cancelledDealId", cancelledId);
        vm.writeJson(json, _path());
    }

    function _loadOrDeploy(uint256 deployerPk) internal returns (TestToken token, Escrow escrow) {
        if (vm.exists(_path())) {
            string memory json = vm.readFile(_path());
            token = TestToken(json.readAddress(".testToken"));
            escrow = Escrow(json.readAddress(".escrow"));
            if (address(escrow).code.length > 0) return (token, escrow);
        }
        vm.startBroadcast(deployerPk);
        token = new TestToken();
        escrow = new Escrow(address(0), 0, 0);
        vm.stopBroadcast();
        console.log("TestToken", address(token));
        console.log("Escrow", address(escrow));
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia.json";
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// Anvil default keys are public; Sepolia requires env.
    function _keys() internal view returns (uint256 holderPk, uint256 providerPk) {
        if (block.chainid == 31337) {
            return (
                0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80,
                0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
            );
        }
        holderPk = vm.envUint("HOLDER_PRIVATE_KEY");
        providerPk = vm.envUint("PROVIDER_PRIVATE_KEY");
    }

    function _activate(
        Escrow escrow,
        TestToken token,
        address holder,
        address provider,
        uint256 holderPk,
        uint256 providerPk,
        uint256 holderNonce,
        uint256 providerNonce
    ) internal returns (bytes32 id) {
        DealTerms memory terms;
        terms.holder = holder;
        terms.controller = holder;
        terms.provider = provider;
        terms.token = address(token);
        terms.principal = PRINCIPAL;
        terms.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        terms.packageIds = new bytes32[](0);

        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: holderNonce, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa =
            ProviderAgreement({terms: terms, nonce: providerNonce, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;

        bytes memory holderSig = _sign(escrow, Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory providerSig = _sign(escrow, Consent.hashProviderAgreement(pa), providerPk);

        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, holderSig, pa, providerSig, ca, "");
        vm.stopBroadcast();
    }

    function _sign(Escrow escrow, bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
