// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualSplit
} from "../../src/libraries/Types.sol";
import {Consent} from "../../src/libraries/Consent.sol";
import {Pool} from "../../src/pools/Pool.sol";
import {PoolFactory} from "../../src/pools/PoolFactory.sol";
import {BaseTest} from "../Base.t.sol";

/// @dev Property tests over the share vault: share math rounds toward the vault, treasury reservations are exact,
///      redeem is bounded by idle, and NAV moves only through consumption.
contract PoolFuzzTest is BaseTest {
    uint256 internal constant MIN_FIRST = 1e6;
    uint256 internal constant MAX_AMOUNT = type(uint96).max;

    PoolFactory internal factory;
    address internal sponsor = address(0x5B);
    address internal lpA = address(0xA1);
    address internal lpB = address(0xB1);

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory(address(escrow));
    }

    /// Two LPs in, two LPs out, no deals: everybody gets back exactly what they put in and the vault empties.
    function testFuzz_depositRedeem_roundTripWithoutDeals(uint256 a, uint256 b) public {
        a = bound(a, MIN_FIRST, MAX_AMOUNT);
        b = bound(b, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(0);
        _deposit(pool, lpA, a);
        _deposit(pool, lpB, b);
        assertEq(pool.nav(), a + b);

        uint256 sharesA = pool.sharesOf(lpA);
        uint256 sharesB = pool.sharesOf(lpB);
        vm.prank(lpA);
        pool.redeem(sharesA);
        vm.prank(lpB);
        pool.redeem(sharesB);
        assertEq(token.balanceOf(lpA), a, "lpA round trip");
        assertEq(token.balanceOf(lpB), b, "lpB round trip");
        assertEq(pool.totalShares(), 0);
        assertEq(pool.idle(), 0);
        assertEq(token.balanceOf(address(pool)), 0);
    }

    /// Share price never drops on a deposit: rounding favours existing LPs.
    function testFuzz_deposit_neverDilutes(uint256 first, uint256 second) public {
        first = bound(first, MIN_FIRST, MAX_AMOUNT);
        second = bound(second, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(0);
        _deposit(pool, lpA, first);
        uint256 navBefore = pool.nav();
        uint256 sharesBefore = pool.totalShares();
        _deposit(pool, lpB, second);
        // price = nav / shares; compare cross-multiplied
        assertGe(pool.nav() * sharesBefore, navBefore * pool.totalShares(), "share price fell on deposit");
        assertLe(pool.sharesOf(lpB), second, "minted more shares than assets at price >= 1");
    }

    /// `authorize` reserves exactly principal + fee from idle and approves exactly the principal to the escrow.
    function testFuzz_authorize_reservesExact(uint256 deposit, uint256 principal, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 10_000));
        deposit = bound(deposit, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(feeBps);
        _deposit(pool, lpA, deposit);
        principal = bound(principal, 1, deposit);
        uint256 fee = principal * feeBps / 10_000;

        DealTerms memory t = _terms(pool, principal);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        vm.prank(controller);
        if (principal + fee > deposit) {
            vm.expectRevert(Pool.InsufficientIdle.selector);
            pool.authorize(ha, _noMods());
            return;
        }
        pool.authorize(ha, _noMods());
        assertEq(pool.idle(), deposit - principal - fee, "idle not reduced by principal + fee");
        assertEq(pool.locked(), principal + fee, "locked != principal + fee");
        assertEq(pool.nav(), deposit, "authorize changed NAV");
        assertEq(token.allowance(address(pool), address(escrow)), principal, "allowance != principal");
        assertEq(bytes4(pool.isValidSignature(_typed(_hashHolderAuth(ha)), "")), bytes4(0x1626ba7e));
    }

    /// Redeem pays shares * nav / totalShares and reverts iff that exceeds idle (locked is receivable).
    function testFuzz_redeem_boundedByIdle(uint256 deposit, uint256 principal, uint256 sharesIn) public {
        deposit = bound(deposit, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(0);
        _deposit(pool, lpA, deposit);
        principal = bound(principal, 1, deposit);
        DealTerms memory t = _terms(pool, principal);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());

        sharesIn = bound(sharesIn, 1, pool.sharesOf(lpA));
        uint256 out = sharesIn * pool.nav() / pool.totalShares();
        uint256 idle = pool.idle();
        if (out > idle) {
            vm.prank(lpA);
            vm.expectRevert(Pool.RedeemExceedsIdle.selector);
            pool.redeem(sharesIn);
        } else if (out == 0) {
            vm.prank(lpA);
            vm.expectRevert(Pool.InsufficientShares.selector);
            pool.redeem(sharesIn);
        } else {
            vm.prank(lpA);
            pool.redeem(sharesIn);
            assertEq(token.balanceOf(lpA), out);
            assertEq(pool.locked(), principal, "redeem touched locked");
        }
    }

    /// Provider-positive terminal: NAV drops by exactly principal - returned (+ Controller fee); holder-positive: unchanged.
    function testFuzz_reconcile_navDropsOnlyByConsumption(uint256 deposit, uint256 principal, uint16 feeBps, uint16 bps)
        public
    {
        feeBps = uint16(bound(feeBps, 0, 1000));
        bps = uint16(bound(bps, 0, 10_000));
        deposit = bound(deposit, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(feeBps);
        _deposit(pool, lpA, deposit);
        principal = bound(principal, 1, deposit * 10_000 / (10_000 + feeBps));
        uint256 fee = principal * feeBps / 10_000;
        vm.assume(principal + fee <= deposit);

        DealTerms memory t = _terms(pool, principal);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca = _controllerAuth(t, 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        assertEq(pool.nav(), deposit, "NAV moved on activation");

        _markFiat(id);
        _splitAsController(id, bps);
        (, uint256 returned,) = escrow.settlementOf(id);
        assertEq(pool.nav(), deposit - (principal - returned), "preview NAV != deposit - consumed principal");

        pool.reconcile(1);
        uint256 feePaid = returned < principal ? fee : 0;
        assertEq(pool.nav(), deposit - (principal - returned) - feePaid, "NAV after reconcile");
        assertEq(pool.consumed(), (principal - returned) + feePaid, "consumed");
        assertEq(pool.locked(), 0, "locked after reconcile");
        assertEq(pool.credits(), 0, "credits after reconcile");
        assertEq(token.balanceOf(controller), feePaid, "controller fee");
        assertEq(token.balanceOf(address(pool)), pool.idle(), "idle != balance once flat");
        assertEq(token.allowance(address(pool), address(escrow)), 0, "allowance not cleared");
    }

    /// An expired, unused auth unlocks its full reservation back to idle and drops the allowance.
    function testFuzz_unlock_restoresReservation(uint256 deposit, uint256 principal, uint16 feeBps, uint256 elapsed)
        public
    {
        feeBps = uint16(bound(feeBps, 0, 1000));
        deposit = bound(deposit, MIN_FIRST, MAX_AMOUNT);
        Pool pool = _openPool(feeBps);
        _deposit(pool, lpA, deposit);
        principal = bound(principal, 1, deposit * 10_000 / (10_000 + feeBps));
        vm.assume(principal + principal * feeBps / 10_000 <= deposit);
        DealTerms memory t = _terms(pool, principal);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());

        elapsed = bound(elapsed, 0, 3 days);
        vm.warp(block.timestamp + elapsed);
        if (block.timestamp <= ha.deadline) {
            vm.expectRevert(Pool.DeadlineActive.selector);
            pool.unlock(1);
            return;
        }
        pool.unlock(1);
        assertEq(pool.idle(), deposit);
        assertEq(pool.locked(), 0);
        assertEq(token.allowance(address(pool), address(escrow)), 0);
        assertEq(bytes4(pool.isValidSignature(_typed(_hashHolderAuth(ha)), "")), bytes4(0));
    }

    // --- helpers -----------------------------------------------------------------------------------------

    function _openPool(uint16 feeBps) internal returns (Pool) {
        address[] memory sps = new address[](1);
        sps[0] = sponsor;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory none = new address[](0);
        return Pool(factory.createPool(sps, address(token), cs, true, none, feeBps));
    }

    function _deposit(Pool pool, address lp, uint256 amount) internal {
        token.mint(lp, amount);
        vm.startPrank(lp);
        token.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _terms(Pool pool, uint256 principal) internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
        t.principal = principal;
    }

    function _hashHolderAuth(HolderAuthorization memory ha) internal pure returns (bytes32) {
        return Consent.hashHolderAuthorization(ha);
    }

    function _splitAsController(bytes32 id, uint16 bps) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: 2, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: 2, deadline: deadline});
        escrow.mutualSplit(
            p,
            _sign(_typed(Consent.hashMutualSplit(p)), providerPk),
            c,
            _sign(_typed(Consent.hashMutualSplit(c)), controllerPk)
        );
    }
}
