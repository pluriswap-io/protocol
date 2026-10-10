// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Terms} from "../src/libraries/Terms.sol";
import {Settlement} from "../src/libraries/Settlement.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
import {Escrow} from "../src/Escrow.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";

contract ActivateTest is BaseTest {
    function test_activate_p2p_fundedPullsExact() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        ControllerAcceptance memory ca;

        bytes32 id = escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");

        bytes32 expected = Consent.dealId(escrow.domainSeparator(), ha.terms, ha.nonce, pa.nonce, 0);
        assertEq(id, expected);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertTrue(escrow.used(holder, ha.nonce));
        assertTrue(escrow.used(provider, pa.nonce));
    }

    /// The kernel's own half of an activation, measured clean: consent, the deal id, the pull and the
    /// storage — no packages, no proofs. It is the baseline the private path is compared against in
    /// EVALUACION.md's LHF-5, and the last piece of that decomposition that was missing.
    function test_activate_coreGas() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);

        uint256 before = gasleft();
        escrow.activate(ha, hs, pa, ps, ca, "");
        emit log_named_uint("Core activate (no packages)", before - gasleft());
    }

    function test_activate_emitsActivated() public {
        DealTerms memory terms = _p2pTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        bytes32 id = Consent.dealId(escrow.domainSeparator(), terms, ha.nonce, pa.nonce, 0);

        vm.recordLogs();
        escrow.activate(ha, hs, pa, ps, ca, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("Activated(bytes32,address,address,address,address,uint256)");
        bytes memory data = abi.encode(holder, provider, holder, address(token), PRINCIPAL);
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(escrow) && logs[i].topics[0] == topic0) {
                assertEq(logs[i].topics[1], id, "dealId is the indexed topic");
                assertEq(logs[i].data, data);
                found = true;
            }
        }
        assertTrue(found);
    }

    /// A deal with yourself moves no value: it exists only to feed a reputation meant to measure
    /// counterparties. The kernel closes it at the strongest possible place — the TERMS cannot hash,
    /// so they cannot be signed and no such deal can be built at all. Pinned here because the
    /// 2026-09-23 anti-farming work builds on it: with the address case structurally impossible, the
    /// only self-deal left was the SUBJECT one (two wallets, one private account), which `Packages`
    /// now rejects with `SameSubject`. Two different accounts of the same human stay undetectable by
    /// construction, and that is what the counterparty set prices instead.
    function test_terms_cannotEvenHashASelfDeal() public {
        DealTerms memory t = _p2pTerms();
        t.provider = holder;
        vm.expectRevert(Terms.HolderEqualsProvider.selector);
        Terms.hashTerms(t);
    }

    function test_activate_revertsIfHolderSigBad() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signProvider(pa);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.InvalidHolderSignature.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfProviderSigBad() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signHolder(ha);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfMissingControllerAcceptance() public {
        DealTerms memory terms = _poolTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.ControllerAcceptanceRequired.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfNonceReplay() public {
        _activateP2P(1, 1);
        token.mint(holder, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 2);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfProviderNonceReplay() public {
        _activateP2P(1, 1);
        token.mint(holder, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 2);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_failedPull_doesNotConsumeNonce() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(holder, PRINCIPAL);
        vm.prank(holder);
        feeToken.approve(address(escrow), PRINCIPAL);

        DealTerms memory terms = _p2pTerms();
        terms.token = address(feeToken);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;

        vm.expectRevert(Settlement.InexactPull.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");

        assertFalse(escrow.used(holder, ha.nonce));
        assertFalse(escrow.used(provider, pa.nonce));
    }

    function test_activate_revertsIfDeadlinePassed() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.warp(ha.deadline + 1);
        vm.expectRevert(Escrow.DeadlinePassed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_twoConcurrentDealsDifferentNonces() public {
        token.mint(holder, PRINCIPAL);
        bytes32 id1 = _activateP2P(1, 1);
        bytes32 id2 = _activateP2P(2, 2);
        assertTrue(id1 != id2);
        assertEq(uint8(escrow.status(id1)), uint8(Status.FUNDED));
        assertEq(uint8(escrow.status(id2)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL * 2);
    }

    function test_cancelNonce_blocksActivate() public {
        vm.prank(holder);
        escrow.cancelNonce(1);

        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;

        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfHolderEqualsProvider() public {
        DealTerms memory terms = _p2pTerms();
        terms.provider = holder;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        vm.expectRevert(Terms.HolderEqualsProvider.selector);
        escrow.activate(ha, hex"", pa, hex"", ca, "");
    }

    /// The Provider cannot also be the Controller: it would release the principal to itself.
    function test_activate_revertsIfControllerEqualsProvider() public {
        DealTerms memory terms = _p2pTerms();
        terms.controller = provider;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        vm.expectRevert(Terms.ControllerEqualsProvider.selector);
        escrow.activate(ha, hex"", pa, hex"", ca, "");
    }

    function test_activate_revertsOnZeroAddressRole() public {
        ControllerAcceptance memory ca;
        for (uint256 slot; slot < 4; slot++) {
            DealTerms memory terms = _p2pTerms();
            if (slot == 0) terms.holder = address(0);
            else if (slot == 1) terms.controller = address(0);
            else if (slot == 2) terms.provider = address(0);
            else terms.token = address(0);
            HolderAuthorization memory ha = _holderAuth(terms, 1);
            ProviderAgreement memory pa = _providerAuth(terms, 1);
            vm.expectRevert(Terms.ZeroAddress.selector);
            escrow.activate(ha, hex"", pa, hex"", ca, "");
        }
    }

    /// The Holder commits to receiving one payment, the Provider signs a different one: those are two
    /// deals, and neither signature can fund the other.
    function test_activate_revertsIfFiatLegsDiffer() public {
        DealTerms memory hTerms = _p2pTerms();
        DealTerms memory pTerms = _p2pTerms();
        pTerms.fiatCommit = keccak256("a cheaper payment");
        HolderAuthorization memory ha = _holderAuth(hTerms, 1);
        ProviderAgreement memory pa = _providerAuth(pTerms, 1);
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.TermsMismatch.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
        assertFalse(escrow.used(holder, 1));
    }

    /// A new Core field is a new kernel (§E.3.13): the domain version moves with the typehash, so a
    /// signature made for version 1 can never be replayed against this one.
    function test_domain_isVersion2() public view {
        (, string memory name, string memory version,,,,) = escrow.eip712Domain();
        assertEq(name, "PluriSwap");
        assertEq(version, "2");
    }
}
