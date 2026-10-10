// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @dev Broadcasts every Core terminal path (CASE-CORE-03..15). Packages are out of scope.
contract Paths is Script {
    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant PATHS = 12;

    uint256 internal holderPk;
    uint256 internal providerPk;
    address internal holder;
    address internal provider;
    TestToken internal token;
    Escrow internal escrow;
    uint256 internal actNonce = 1;
    uint256 internal dualNonce = 1000;

    function run() external {
        (holderPk, providerPk) = _keys();
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);

        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.005 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        (token, escrow) = _loadOrDeploy();
        _writeAddresses();

        vm.startBroadcast(holderPk);
        token.mint(holder, PRINCIPAL * PATHS);
        token.approve(address(escrow), type(uint256).max);
        vm.stopBroadcast();

        bytes32 cancelProvider = _pathCancelProvider();
        bytes32 timeoutFiat = _pathTimeoutFiat();
        bytes32 mutualFunded = _pathMutualFunded();
        bytes32 controllerRelease = _pathControllerRelease();
        bytes32 claim = _pathClaim();
        bytes32 mutualFiat = _pathMutualFiat();
        bytes32 splitFiat = _pathSplitFiat();
        bytes32 cosignedFiat = _pathCosignedFiat();
        bytes32 mutualDisputed = _pathMutualDisputed();
        bytes32 cosignedDisputed = _pathCosignedDisputed();
        bytes32 splitDisputed = _pathSplitDisputed();
        bytes32 abandoned = _pathAbandoned();

        require(escrow.status(cancelProvider) == Status.CANCELLED, "03");
        require(escrow.status(timeoutFiat) == Status.CANCELLED, "04");
        require(escrow.status(mutualFunded) == Status.CANCELLED, "05");
        require(escrow.status(controllerRelease) == Status.RELEASED, "06");
        // CLAIMED is its own terminal since 2026-09-12: same economics as RELEASED, different origin
        // and a different reputation reading. This script had not been run since.
        require(escrow.status(claim) == Status.CLAIMED, "07");
        require(escrow.status(mutualFiat) == Status.CANCELLED, "08");
        require(escrow.status(splitFiat) == Status.RESOLVED_SPLIT, "09");
        require(escrow.status(cosignedFiat) == Status.RELEASED, "10");
        require(escrow.status(mutualDisputed) == Status.CANCELLED, "12");
        require(escrow.status(cosignedDisputed) == Status.RELEASED, "13");
        require(escrow.status(splitDisputed) == Status.CANCELLED, "14: split rejected, then cancelled");
        // CASE-CORE-15 in Core (no tribunal): nobody gave way before the clock, so the principal burns.
        require(escrow.status(abandoned) == Status.STALEMATE, "15: no tribunal, nobody gave way");

        console.log("03 cancelByProvider", vm.toString(cancelProvider));
        console.log("04 timeoutFiat    ", vm.toString(timeoutFiat));
        console.log("05 mutual FUNDED  ", vm.toString(mutualFunded));
        console.log("06 release        ", vm.toString(controllerRelease));
        console.log("07 claim          ", vm.toString(claim));
        console.log("08 mutual FIAT    ", vm.toString(mutualFiat));
        console.log("09 split FIAT     ", vm.toString(splitFiat));
        console.log("10 cosigned FIAT  ", vm.toString(cosignedFiat));
        console.log("12 mutual DISPUTED", vm.toString(mutualDisputed));
        console.log("13 cosigned DISP  ", vm.toString(cosignedDisputed));
        console.log("14 split rejected ", vm.toString(splitDisputed));
        console.log("15 deadlock       ", vm.toString(abandoned));
    }

    function _pathCancelProvider() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        vm.startBroadcast(providerPk);
        escrow.cancelByProvider(id);
        vm.stopBroadcast();
    }

    function _pathTimeoutFiat() internal returns (bytes32 id) {
        id = _activate(_terms(0, 1800, 7200));
        vm.startBroadcast(holderPk);
        escrow.timeoutFiat(id);
        vm.stopBroadcast();
    }

    function _pathMutualFunded() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        _broadcastMutualCancel(id);
    }

    function _pathControllerRelease() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        _broadcastMarkFiat(id);
        vm.startBroadcast(holderPk);
        escrow.release(id);
        vm.stopBroadcast();
    }

    function _pathClaim() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 0, 7200));
        _broadcastMarkFiat(id);
        vm.startBroadcast(holderPk);
        escrow.claim(id);
        vm.stopBroadcast();
    }

    function _pathMutualFiat() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        _broadcastMarkFiat(id);
        _broadcastMutualCancel(id);
    }

    function _pathSplitFiat() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        _broadcastMarkFiat(id);
        _broadcastSplit(id, 2500);
    }

    function _pathCosignedFiat() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 1800, 7200));
        _broadcastMarkFiat(id);
        _broadcastCosigned(id);
    }

    function _pathMutualDisputed() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 100, 7200));
        _broadcastMarkFiat(id);
        _broadcastOpenDisputed(id);
        _broadcastMutualCancel(id);
    }

    function _pathCosignedDisputed() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 100, 7200));
        _broadcastMarkFiat(id);
        _broadcastOpenDisputed(id);
        _broadcastCosigned(id);
    }

    /// CASE-CORE-14 since 2026-09-24: after a dispute a split is not on offer (it is what the clock's threat
    /// would extract). Checked locally — a reverting call is never broadcast — and the deal is then closed
    /// the way a dispute can still close by agreement: all-or-nothing, here a mutual cancel.
    function _pathSplitDisputed() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 100, 7200));
        _broadcastMarkFiat(id);
        _broadcastOpenDisputed(id);
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 4000, nonce: dualNonce++, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 4000, nonce: dualNonce++, deadline: deadline});
        bytes memory pSig = _sign(Consent.hashMutualSplit(p), providerPk);
        bytes memory cSig = _sign(Consent.hashMutualSplit(c), holderPk);
        try escrow.mutualSplit(p, pSig, c, cSig) {
            revert("14: a split after a dispute must be rejected");
        } catch (bytes memory reason) {
            require(bytes4(reason) == Escrow.SplitAfterDispute.selector, "14: wrong rejection");
        }
        _broadcastMutualCancel(id);
    }

    function _pathAbandoned() internal returns (bytes32 id) {
        id = _activate(_terms(3600, 100, 0));
        _broadcastMarkFiat(id);
        _broadcastOpenDisputed(id);
        vm.startBroadcast(holderPk);
        escrow.forceDisputeTimeout(id);
        vm.stopBroadcast();
    }

    function _terms(uint256 fiat, uint256 release, uint256 dispute) internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = PRINCIPAL;
        t.fiatDuration = fiat;
        t.releaseDuration = release;
        t.disputeDuration = dispute;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        t.packageIds = new bytes32[](0);
    }

    function _activate(DealTerms memory terms) internal returns (bytes32 id) {
        uint256 n = actNonce++;
        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: n, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: terms, nonce: n, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        bytes memory holderSig = _sign(Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory providerSig = _sign(Consent.hashProviderAgreement(pa), providerPk);
        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, holderSig, pa, providerSig, ca, "");
        vm.stopBroadcast();
    }

    function _broadcastMarkFiat(bytes32 id) internal {
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
    }

    function _broadcastOpenDisputed(bytes32 id) internal {
        vm.startBroadcast(holderPk);
        escrow.openDisputed(id);
        vm.stopBroadcast();
    }

    function _broadcastMutualCancel(bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualCancel memory p = MutualCancel({dealId: id, nonce: dualNonce++, deadline: deadline});
        MutualCancel memory c = MutualCancel({dealId: id, nonce: dualNonce++, deadline: deadline});
        bytes memory pSig = _sign(Consent.hashMutualCancel(p), providerPk);
        bytes memory cSig = _sign(Consent.hashMutualCancel(c), holderPk);
        vm.startBroadcast(holderPk);
        escrow.mutualCancel(p, pSig, c, cSig);
        vm.stopBroadcast();
    }

    function _broadcastCosigned(bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 days;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: dualNonce++, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: dualNonce++, deadline: deadline});
        bytes memory pSig = _sign(Consent.hashCoSignedRelease(p), providerPk);
        bytes memory cSig = _sign(Consent.hashCoSignedRelease(c), holderPk);
        vm.startBroadcast(holderPk);
        escrow.coSignedRelease(p, pSig, c, cSig);
        vm.stopBroadcast();
    }

    function _broadcastSplit(bytes32 id, uint16 bps) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: dualNonce++, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: dualNonce++, deadline: deadline});
        bytes memory pSig = _sign(Consent.hashMutualSplit(p), providerPk);
        bytes memory cSig = _sign(Consent.hashMutualSplit(c), holderPk);
        vm.startBroadcast(holderPk);
        escrow.mutualSplit(p, pSig, c, cSig);
        vm.stopBroadcast();
    }

    function _sign(bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _loadOrDeploy() internal returns (TestToken t, Escrow e) {
        vm.startBroadcast(holderPk);
        t = new TestToken();
        e = new Escrow(address(0), 0, 0);
        vm.stopBroadcast();
        console.log("TestToken", address(t));
        console.log("Escrow", address(e));
    }

    function _writeAddresses() internal {
        string memory obj = "paths";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        string memory json = vm.serializeAddress(obj, "escrow", address(escrow));
        string memory path = block.chainid == 421614
            ? "deployments/sepolia-paths.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-paths.json");
        vm.writeJson(json, path);
        console.log("wrote", path);
    }

    function _keys() internal view returns (uint256 h, uint256 p) {
        if (block.chainid == 31337) {
            return (
                0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80,
                0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
            );
        }
        h = vm.envUint("HOLDER_PRIVATE_KEY");
        p = vm.envUint("PROVIDER_PRIVATE_KEY");
    }
}
