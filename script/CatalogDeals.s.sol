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
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";

/// @dev Sepolia catalog: ZK FUNDED→verifyProof→RELEASED, then arb markFiat→openCourt→holder win.
contract CatalogDeals is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant COURT_FEE = 1_000_000;
    /// @dev Mirrors `DeployPackages`: the two contest-open invoices a fight costs in this stack.
    uint256 internal constant CONTEST_FLOOR = 2_000_000;
    uint256 internal constant COURT_CONTEST = 500_000;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 holderPk = _holderKey();
        uint256 providerPk = _providerKey();
        address holder = vm.addr(holderPk);
        address provider = vm.addr(providerPk);

        string memory catalog = vm.readFile(_path());
        TestToken token = TestToken(catalog.readAddress(".testToken"));
        Escrow escrow = Escrow(catalog.readAddress(".escrow"));
        address zkMod = catalog.readAddress(".zk");
        ArbitrationMock arb = ArbitrationMock(catalog.readAddress(".arbitration"));
        address feeRecipient = catalog.readAddress(".feeRecipient");
        address tribunal = arb.tribunal();
        require(address(escrow).code.length > 0, "escrow");

        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.005 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        vm.startBroadcast(holderPk);
        // Two deals with the kernel's activation share on top, the court fee, and the contest-open invoices
        // of BOTH packages: the reputation floor and the court's own (PROTOCOLO.md §E.3.14.6). Opening a
        // fight costs each of them.
        uint256 kernelFee = PRINCIPAL * escrow.activationBps() / 10_000;
        token.mint(holder, (PRINCIPAL + kernelFee) * 2 + COURT_FEE + (CONTEST_FLOOR + COURT_CONTEST) * 2);
        token.approve(address(escrow), type(uint256).max);
        token.approve(address(arb), type(uint256).max);
        vm.stopBroadcast();

        bytes32 zkId = _activate(
            escrow,
            token,
            holder,
            provider,
            holderPk,
            providerPk,
            2,
            2,
            _one(catalog.readBytes32(".zkId")),
            0,
            _zkMods(zkMod)
        );
        // Left FUNDED on purpose: the proof names the deal's on-chain activation clock, which a script
        // cannot know until the activation is MINED — the same order a real Provider follows (pay after
        // funding, prove after paying). `ZkRelease` proves it in the next run.
        require(escrow.status(zkId) == Status.FUNDED, "zk funded");

        bytes32 arbDeal = _activate(
            escrow,
            token,
            holder,
            provider,
            holderPk,
            providerPk,
            3,
            3,
            _one(catalog.readBytes32(".arbId")),
            1 days,
            _courtMods(address(arb))
        );
        vm.startBroadcast(providerPk);
        escrow.markFiat(arbDeal);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.openCourt(arbDeal);
        vm.stopBroadcast();
        require(escrow.status(arbDeal) == Status.ARBITRATION_ACTIVE, "court open");
        vm.startBroadcast(holderPk);
        arb.submitRuling(arbDeal, ArbitrationMock.Ruling.HolderWin);
        escrow.readRuling(arbDeal);
        vm.stopBroadcast();
        require(escrow.status(arbDeal) == Status.RESOLVED_BY_ARBITRATION, "arb resolved");
        require(token.balanceOf(tribunal) >= COURT_FEE, "court fee");

        console.log("zkDeal", vm.toString(zkId));
        console.log("zkStatus", uint256(escrow.status(zkId)));
        console.log("arbDeal", vm.toString(arbDeal));
        console.log("arbStatus", uint256(escrow.status(arbDeal)));
        console.log("feeRecipient", token.balanceOf(feeRecipient));
        console.log("tribunal", token.balanceOf(tribunal));

        _write(catalog, zkId, arbDeal);
    }

    function _activate(
        Escrow escrow,
        TestToken token,
        address holder,
        address provider,
        uint256 holderPk,
        uint256 providerPk,
        uint256 holderNonce,
        uint256 providerNonce,
        bytes32[] memory packageIds,
        uint256 arbitrationDuration,
        PackageMods memory mods
    ) internal returns (bytes32 id) {
        DealTerms memory terms;
        terms.holder = holder;
        terms.controller = holder;
        terms.provider = provider;
        terms.token = address(token);
        terms.principal = PRINCIPAL;
        terms.fiatDuration = 3600;
        terms.releaseDuration = 1800;
        terms.disputeDuration = 7200;
        terms.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        terms.arbitrationDuration = arbitrationDuration;
        terms.packageIds = packageIds;

        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: holderNonce, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa =
            ProviderAgreement({terms: terms, nonce: providerNonce, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;

        bytes memory holderSig = _sign(escrow, Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory providerSig = _sign(escrow, Consent.hashProviderAgreement(pa), providerPk);

        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, holderSig, pa, providerSig, ca, "", mods);
        vm.stopBroadcast();
    }

    function _zkMods(address zk) internal pure returns (PackageMods memory m) {
        m.zk = zk;
    }

    function _courtMods(address court) internal pure returns (PackageMods memory m) {
        m.court = court;
    }

    function _write(string memory catalog, bytes32 zkDealId, bytes32 arbDealId) internal {
        string memory obj = "packages";
        vm.serializeUint(obj, "chainId", catalog.readUint(".chainId"));
        vm.serializeAddress(obj, "testToken", catalog.readAddress(".testToken"));
        vm.serializeAddress(obj, "passport", catalog.readAddress(".passport"));
        vm.serializeAddress(obj, "reputation", catalog.readAddress(".reputation"));
        vm.serializeAddress(obj, "bondVault", catalog.readAddress(".bondVault"));
        vm.serializeAddress(obj, "verifier", catalog.readAddress(".verifier"));
        vm.serializeAddress(obj, "zk", catalog.readAddress(".zk"));
        vm.serializeAddress(obj, "arbitration", catalog.readAddress(".arbitration"));
        vm.serializeAddress(obj, "feeRecipient", catalog.readAddress(".feeRecipient"));
        vm.serializeAddress(obj, "sink", catalog.readAddress(".sink"));
        vm.serializeAddress(obj, "escrow", catalog.readAddress(".escrow"));
        vm.serializeBytes32(obj, "passportId", catalog.readBytes32(".passportId"));
        vm.serializeBytes32(obj, "reputationId", catalog.readBytes32(".reputationId"));
        vm.serializeBytes32(obj, "bondsId", catalog.readBytes32(".bondsId"));
        vm.serializeBytes32(obj, "zkId", catalog.readBytes32(".zkId"));
        vm.serializeBytes32(obj, "arbId", catalog.readBytes32(".arbId"));
        vm.serializeBytes32(obj, "releasedDealId", catalog.readBytes32(".releasedDealId"));
        // Carry the panel through: this rewrite owns only its own keys.
        if (vm.keyExistsJson(catalog, ".panel")) {
            vm.serializeAddress(obj, "panel", catalog.readAddress(".panel"));
            vm.serializeBytes32(obj, "panelId", catalog.readBytes32(".panelId"));
        }
        vm.serializeBytes32(obj, "zkDealId", zkDealId);
        string memory json = vm.serializeBytes32(obj, "arbDealId", arbDealId);
        vm.writeJson(json, _path());
        console.log("wrote", _path());
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _sign(Escrow escrow, bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    function _holderKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }

    function _providerKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }
        pk = vm.envUint("PROVIDER_PRIVATE_KEY");
    }
}
