// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualSplit
} from "../../src/libraries/Types.sol";
import {Consent} from "../../src/libraries/Consent.sol";
import {Terms} from "../../src/libraries/Terms.sol";
import {Clocks} from "../../src/libraries/Clocks.sol";
import {Escrow} from "../../src/Escrow.sol";
import {TokenThatRejectsReceiver} from "../../mocks/RevertingReceiver.sol";
import {BaseTest} from "../Base.t.sol";

/// @dev Property tests over the Core kernel: conservation, clock boundaries, nonce binding, typed-data injectivity.
contract KernelFuzzTest is BaseTest {
    uint256 internal constant MAX_PRINCIPAL = type(uint128).max;
    uint256 internal constant MAX_DURATION = 100 * 365 days;

    // --- conservation ------------------------------------------------------------------------------

    function testFuzz_mutualSplit_conservesPrincipal(uint256 principal, uint16 bps) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        bps = uint16(bound(bps, 0, 10_000));
        bytes32 id = _activateWithPrincipal(principal, 1, 1);
        _markFiat(id);
        _mutualSplit(id, bps, 2, 2);

        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.RESOLVED_SPLIT));
        assertEq(p, principal * bps / 10_000, "provider share != bps of principal");
        assertEq(h + p, principal, "split does not conserve principal");
        assertEq(token.balanceOf(provider), p);
        assertEq(token.balanceOf(address(escrow)), 0, "escrow keeps dust after split");
    }

    /// A deal without a tribunal: every dispute nobody settles is a deadlock, and every wei of it is burned —
    /// none to either party, none left in custody.
    function testFuzz_forceDisputeTimeout_withoutATribunal_burns(uint256 principal, uint256 disputeDuration) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        disputeDuration = bound(disputeDuration, 0, MAX_DURATION);
        DealTerms memory t = _p2pTerms();
        t.principal = principal;
        t.disputeDuration = disputeDuration;
        token.mint(holder, principal);
        bytes32 id = _activateP2PWith(t, 1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + disputeDuration);
        escrow.forceDisputeTimeout(id);

        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.STALEMATE));
        assertEq(h + p, 0, "a deadlock pays nobody");
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), principal, "every wei burned");
        assertEq(token.balanceOf(address(escrow)), 0, "nothing left in custody");
    }

    function testFuzz_everyTerminal_paysExactlyPrincipal(uint256 principal, uint8 path) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        path = uint8(bound(path, 0, 6));
        bytes32 id = _activateWithPrincipal(principal, 1, 1);
        uint256 holderBefore = token.balanceOf(holder);

        if (path == 0) {
            vm.prank(provider);
            escrow.cancelByProvider(id);
        } else if (path == 1) {
            vm.warp(block.timestamp + 3600);
            escrow.timeoutFiat(id);
        } else if (path == 2) {
            _mutualCancel(id, 2, 2);
        } else if (path == 3) {
            _markFiat(id);
            vm.prank(holder);
            escrow.release(id);
        } else if (path == 4) {
            _markFiat(id);
            vm.warp(block.timestamp + 1800);
            escrow.claim(id);
        } else if (path == 5) {
            _markFiat(id);
            _coSignedRelease(id, 2, 2);
        } else {
            _markFiat(id);
            _openDisputed(id);
            _mutualCancel(id, 2, 2);
        }

        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertTrue(s == Status.CANCELLED || s == Status.RELEASED || s == Status.CLAIMED, "unexpected terminal");
        assertEq(h + p, principal, "terminal does not conserve principal");
        assertEq(token.balanceOf(holder) - holderBefore, h, "holder push != holderAmt");
        assertEq(token.balanceOf(provider), p, "provider push != providerAmt");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow keeps principal after terminal");
    }

    /// Credit-first: a Provider the token refuses still gets RELEASED and an exact credit; principal never moves elsewhere.
    function testFuzz_creditFirst_rejectingProvider(uint256 principal) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        TokenThatRejectsReceiver rejecting = new TokenThatRejectsReceiver(provider);
        rejecting.mint(holder, principal);
        vm.prank(holder);
        rejecting.approve(address(escrow), type(uint256).max);
        DealTerms memory t = _p2pTerms();
        t.token = address(rejecting);
        t.principal = principal;
        bytes32 id = _activateP2PWith(t, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);

        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(escrow.creditOf(address(rejecting), provider), principal, "credit != principal");
        assertEq(rejecting.balanceOf(address(escrow)), principal, "escrow must still hold the credited principal");
        assertEq(rejecting.balanceOf(provider), 0);
    }

    // --- clocks -----------------------------------------------------------------------------------

    function testFuzz_timeoutFiat_dueIffElapsed(uint256 fiatDuration, uint256 elapsed) public {
        fiatDuration = bound(fiatDuration, 0, MAX_DURATION);
        elapsed = bound(elapsed, 0, 2 * MAX_DURATION);
        DealTerms memory t = _p2pTerms();
        t.fiatDuration = fiatDuration;
        bytes32 id = _activateP2PWith(t, 1, 1);
        vm.warp(block.timestamp + elapsed);
        if (elapsed < fiatDuration) {
            vm.expectRevert(Clocks.TooEarly.selector);
            escrow.timeoutFiat(id);
            assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        } else {
            escrow.timeoutFiat(id);
            assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        }
    }

    /// CASE-RACE-03: at the release deadline `claim` wins and `openDisputed` is TooLate; before it the reverse.
    function testFuzz_claimAndDispute_areComplementaryAtDeadline(uint256 releaseDuration, uint256 elapsed) public {
        releaseDuration = bound(releaseDuration, 0, MAX_DURATION);
        elapsed = bound(elapsed, 0, 2 * MAX_DURATION);
        DealTerms memory t = _p2pTerms();
        t.releaseDuration = releaseDuration;
        bytes32 id = _activateP2PWith(t, 1, 1);
        _markFiat(id);
        vm.warp(block.timestamp + elapsed);
        if (elapsed < releaseDuration) {
            vm.expectRevert(Clocks.TooEarly.selector);
            escrow.claim(id);
            _openDisputed(id);
            assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
        } else {
            vm.prank(holder);
            vm.expectRevert(Clocks.TooLate.selector);
            escrow.openDisputed(id);
            escrow.claim(id);
            assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
        }
    }

    function testFuzz_forceDisputeTimeout_dueIffElapsed(uint256 disputeDuration, uint256 elapsed) public {
        disputeDuration = bound(disputeDuration, 0, MAX_DURATION);
        elapsed = bound(elapsed, 0, 2 * MAX_DURATION);
        DealTerms memory t = _p2pTerms();
        t.disputeDuration = disputeDuration;
        bytes32 id = _activateP2PWith(t, 1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + elapsed);
        if (elapsed < disputeDuration) {
            vm.expectRevert(Clocks.TooEarly.selector);
            escrow.forceDisputeTimeout(id);
        } else {
            escrow.forceDisputeTimeout(id);
            assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        }
    }

    function testFuzz_activate_respectsEveryDeadline(uint256 offset, uint256 elapsed) public {
        offset = bound(offset, 0, MAX_DURATION);
        elapsed = bound(elapsed, 0, 2 * MAX_DURATION);
        DealTerms memory t = _p2pTerms();
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ha.deadline = block.timestamp + offset;
        pa.deadline = block.timestamp + offset;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.warp(block.timestamp + elapsed);
        if (elapsed > offset) {
            vm.expectRevert(Escrow.DeadlinePassed.selector);
            escrow.activate(ha, hs, pa, ps, ca, "");
            assertFalse(escrow.used(holder, 1), "nonce consumed by a rejected activation");
        } else {
            escrow.activate(ha, hs, pa, ps, ca, "");
            assertTrue(escrow.used(holder, 1));
        }
    }

    // --- nonces and typed data -------------------------------------------------------------------------

    function testFuzz_nonce_singleUse(uint256 hNonce, uint256 pNonce) public {
        bytes32 id = _activateP2P(hNonce, pNonce);
        assertEq(escrow.dealOf(holder, hNonce), id);
        assertEq(escrow.dealOf(provider, pNonce), id);

        token.mint(holder, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), hNonce);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), unchecked_inc(pNonce));
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");

        ha = _holderAuth(_p2pTerms(), unchecked_inc(hNonce));
        pa = _providerAuth(_p2pTerms(), pNonce);
        hs = _signHolder(ha);
        ps = _signProvider(pa);
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
    }

    function testFuzz_cancelNonce_blocksThatNonceOnly(uint256 n, uint256 other) public {
        vm.assume(n != other);
        vm.prank(holder);
        escrow.cancelNonce(n);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), n);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
        _activateP2P(other, 1);
    }

    function testFuzz_dealId_injectiveInNonces(uint256 h1, uint256 p1, uint256 h2, uint256 p2) public view {
        vm.assume(h1 != h2 || p1 != p2);
        DealTerms memory t = _p2pTerms();
        bytes32 ds = escrow.domainSeparator();
        assertNotEq(Consent.dealId(ds, t, h1, p1, 0), Consent.dealId(ds, t, h2, p2, 0));
    }

    function testFuzz_dealId_controllerNonceOnlyCountsWhenDistinct(uint256 hN, uint256 pN, uint256 c1, uint256 c2)
        public
        view
    {
        bytes32 ds = escrow.domainSeparator();
        DealTerms memory p2p = _p2pTerms();
        assertEq(Consent.dealId(ds, p2p, hN, pN, c1), Consent.dealId(ds, p2p, hN, pN, c2), "p2p reads controller nonce");
        vm.assume(c1 != c2);
        DealTerms memory pooled = _poolTerms();
        assertNotEq(
            Consent.dealId(ds, pooled, hN, pN, c1),
            Consent.dealId(ds, pooled, hN, pN, c2),
            "distinct ignores controller nonce"
        );
    }

    function testFuzz_termsHash_bindsEveryField(uint8 field, uint256 delta) public view {
        field = uint8(bound(field, 0, 8));
        // A duration past uint64 cannot hash at all (Terms.DurationTooLong); within it every bit still binds.
        if (field >= 5) delta = bound(delta, 1, type(uint64).max >> 1);
        vm.assume(delta != 0);
        DealTerms memory a = _p2pTerms();
        DealTerms memory b = _p2pTerms();
        if (field == 0) b.holder = address(uint160(uint256(uint160(b.holder)) ^ delta));
        else if (field == 1) b.controller = address(uint160(uint256(uint160(b.controller)) ^ delta));
        else if (field == 2) b.provider = address(uint160(uint256(uint160(b.provider)) ^ delta));
        else if (field == 3) b.token = address(uint160(uint256(uint160(b.token)) ^ delta));
        else if (field == 4) b.principal = b.principal ^ delta;
        else if (field == 5) b.fiatDuration = b.fiatDuration ^ delta;
        else if (field == 6) b.releaseDuration = b.releaseDuration ^ delta;
        else if (field == 7) b.disputeDuration = b.disputeDuration ^ delta;
        else b.arbitrationDuration = b.arbitrationDuration ^ delta;
        if (field <= 2) vm.assume(b.holder != b.provider);
        if (field == 4) vm.assume(b.principal != 0);
        // Address fields truncate to 160 bits: only a real change must change the hash.
        bool changed = field == 0
            ? a.holder != b.holder
            : field == 1
                ? a.controller != b.controller
                : field == 2 ? a.provider != b.provider : field == 3 ? a.token != b.token : true;
        if (!changed) return;
        assertNotEq(Terms.hashTerms(a), Terms.hashTerms(b), "termsHash ignores a field");
    }

    function testFuzz_termsHash_rejectsUnsortedOrDuplicatePackageIds(bytes32 x, bytes32 y) public {
        DealTerms memory t = _p2pTerms();
        t.packageIds = new bytes32[](2);
        (bytes32 lo, bytes32 hi) = x < y ? (x, y) : (y, x);
        t.packageIds[0] = hi;
        t.packageIds[1] = lo;
        vm.expectRevert(Terms.UnsortedPackageIds.selector);
        Terms.hashTerms(t);
        if (lo != hi) {
            t.packageIds[0] = lo;
            t.packageIds[1] = hi;
            Terms.hashTerms(t);
        }
    }

    function testFuzz_mutualSplit_rejectsBpsOver10000(uint16 bps) public {
        bps = uint16(bound(bps, 10_001, type(uint16).max));
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: 2, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: 3, deadline: deadline});
        bytes memory ps = _sign(_typed(Consent.hashMutualSplit(p)), providerPk);
        bytes memory cs = _sign(_typed(Consent.hashMutualSplit(c)), holderPk);
        vm.expectRevert(Escrow.BpsMismatch.selector);
        escrow.mutualSplit(p, ps, c, cs);
    }

    /// Only the snapshotted Controller can release; any other address (including the Holder of a pooled deal) is rejected.
    function testFuzz_release_onlyController(address caller) public {
        vm.assume(caller != controller);
        assumeNotForgeAddress(caller);
        bytes32 id = _activateDistinctController(1, 1, 1);
        _markFiat(id);
        vm.prank(caller);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);
    }

    // --- helpers ----------------------------------------------------------------------------------

    function _activateWithPrincipal(uint256 principal, uint256 hN, uint256 pN) internal returns (bytes32) {
        DealTerms memory t = _p2pTerms();
        t.principal = principal;
        token.mint(holder, principal);
        return _activateP2PWith(t, hN, pN);
    }

    function unchecked_inc(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x + 1;
        }
    }
}
