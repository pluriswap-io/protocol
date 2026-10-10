// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, MutualCancel, CoSignedRelease, MutualSplit} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract DualSignTest is BaseTest {
    function _pair(bytes32 id, uint256 providerNonce, uint256 controllerNonce)
        internal
        view
        returns (MutualCancel memory p, MutualCancel memory c)
    {
        uint256 deadline = block.timestamp + 1 days;
        p = MutualCancel({dealId: id, nonce: providerNonce, deadline: deadline});
        c = MutualCancel({dealId: id, nonce: controllerNonce, deadline: deadline});
    }

    function _signCancel(MutualCancel memory m, uint256 pk) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashMutualCancel(m)), pk);
    }

    function _signRelease(CoSignedRelease memory m, uint256 pk) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashCoSignedRelease(m)), pk);
    }

    function _signSplit(MutualSplit memory m, uint256 pk) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashMutualSplit(m)), pk);
    }

    function _fiatSent() internal returns (bytes32 id) {
        id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
    }

    function _disputed() internal returns (bytes32 id) {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
    }

    function test_mutualCancel_fromFunded() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        escrow.mutualCancel(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_mutualCancel_fromFiatSent() public {
        bytes32 id = _fiatSent();
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        escrow.mutualCancel(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_mutualCancel_fromDisputed() public {
        bytes32 id = _disputed();
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        escrow.mutualCancel(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_mutualCancel_revertsIfDealIdMismatch() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        c.dealId = bytes32(uint256(id) + 1);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        vm.expectRevert(Escrow.DealIdMismatch.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }

    function test_mutualCancel_revertsIfDeadlineMismatch() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        c.deadline = p.deadline + 1;
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        vm.expectRevert(Escrow.DeadlineMismatch.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }

    function test_mutualCancel_revertsIfBadProviderSig() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, holderPk);
        bytes memory cSig = _signCancel(c, holderPk);
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }

    function test_mutualCancel_consumesNonces() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        escrow.mutualCancel(p, pSig, c, cSig);
        token.mint(holder, PRINCIPAL);
        bytes32 id2 = _activateP2P(2, 2);
        p.dealId = id2;
        c.dealId = id2;
        pSig = _signCancel(p, providerPk);
        cSig = _signCancel(c, holderPk);
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }

    function test_mutualCancel_revertsIfDeadlinePassed() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        vm.warp(p.deadline + 1);
        vm.expectRevert(Escrow.DeadlinePassed.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }

    function test_coSignedRelease_fromFiatSent_paysProvider() public {
        bytes32 id = _fiatSent();
        uint256 deadline = block.timestamp + 1 days;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: 20, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: 21, deadline: deadline});
        bytes memory pSig = _signRelease(p, providerPk);
        bytes memory cSig = _signRelease(c, holderPk);
        escrow.coSignedRelease(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_coSignedRelease_fromDisputed() public {
        bytes32 id = _disputed();
        uint256 deadline = block.timestamp + 1 days;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: 20, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: 21, deadline: deadline});
        bytes memory pSig = _signRelease(p, providerPk);
        bytes memory cSig = _signRelease(c, holderPk);
        escrow.coSignedRelease(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_mutualSplit_fromFiatSent() public {
        bytes32 id = _fiatSent();
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 2500, nonce: 30, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 2500, nonce: 31, deadline: deadline});
        bytes memory pSig = _signSplit(p, providerPk);
        bytes memory cSig = _signSplit(c, holderPk);
        escrow.mutualSplit(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_SPLIT));
        assertEq(token.balanceOf(provider), PRINCIPAL * 2500 / 10_000);
        assertEq(token.balanceOf(holder), PRINCIPAL * 7500 / 10_000);
    }

    /// Once somebody disputes, the only agreements left are all-or-nothing: cancel or release (Anexo R,
    /// 2026-09-24). A split after a dispute is what a cheater extracts by threatening the clock — "half, or
    /// we both lose it all" — so the kernel does not offer it.
    function test_mutualSplit_fromDisputed_rejects() public {
        bytes32 id = _disputed();
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 4000, nonce: 30, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 4000, nonce: 31, deadline: deadline});
        bytes memory pSig = _signSplit(p, providerPk);
        bytes memory cSig = _signSplit(c, holderPk);
        vm.expectRevert(Escrow.SplitAfterDispute.selector);
        escrow.mutualSplit(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
        assertFalse(escrow.used(provider, 30), "a rejected split consumes no nonce");
    }

    function test_mutualSplit_revertsIfBpsMismatch() public {
        bytes32 id = _fiatSent();
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 2500, nonce: 30, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 2501, nonce: 31, deadline: deadline});
        bytes memory pSig = _signSplit(p, providerPk);
        bytes memory cSig = _signSplit(c, holderPk);
        vm.expectRevert(Escrow.BpsMismatch.selector);
        escrow.mutualSplit(p, pSig, c, cSig);
    }

    function test_mutualSplit_revertsIfBpsOver10000() public {
        bytes32 id = _fiatSent();
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 10_001, nonce: 30, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 10_001, nonce: 31, deadline: deadline});
        bytes memory pSig = _signSplit(p, providerPk);
        bytes memory cSig = _signSplit(c, holderPk);
        vm.expectRevert(Escrow.BpsMismatch.selector);
        escrow.mutualSplit(p, pSig, c, cSig);
    }

    function test_mutualSplit_10000_isNotCoSignedReleaseType() public {
        bytes32 id = _fiatSent();
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: 10_000, nonce: 30, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: 10_000, nonce: 31, deadline: deadline});
        bytes memory pSig = _signSplit(p, providerPk);
        bytes memory cSig = _signSplit(c, holderPk);
        escrow.mutualSplit(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_SPLIT));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(token.balanceOf(holder), 0);
    }

    function test_dualSign_anyoneCanRelay() public {
        bytes32 id = _activateP2P(1, 1);
        (MutualCancel memory p, MutualCancel memory c) = _pair(id, 10, 11);
        bytes memory pSig = _signCancel(p, providerPk);
        bytes memory cSig = _signCancel(c, holderPk);
        vm.prank(address(0xDEAD));
        escrow.mutualCancel(p, pSig, c, cSig);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
    }
}
