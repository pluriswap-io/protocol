// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Status, DealTerms, DealClocks, PackageMods} from "../../src/libraries/Types.sol";
import {Escrow} from "../../src/Escrow.sol";
import {HandlerBase, ToggleRejectToken} from "./HandlerBase.sol";

/// @dev Core-only recinto (`packageIds = []`). The token can reject pushes to Holder or Provider,
///      so every terminal exercises credit-first and `withdraw` retries.
contract CoreHandler is HandlerBase {
    uint256 internal constant MAX_PRINCIPAL = 1_000_000e6;

    ToggleRejectToken public token;

    constructor(Escrow escrow_, ToggleRejectToken token_) HandlerBase(escrow_) {
        token = token_;
    }

    function activate(uint256 principal, bool distinct, uint256 fiatDur, uint256 relDur, uint256 dispDur)
        external
        count("activate")
    {
        if (token.rejecting(holder)) return; // mint to a rejecting holder would revert
        principal = bound(principal, 1, MAX_PRINCIPAL);
        DealTerms memory t = _baseTerms(principal, distinct, fiatDur, relDur, dispDur);
        t.token = address(token);
        // The kernel's activation share comes from the Holder on top of the principal.
        uint256 due = principal + principal * escrow.activationBps() / 10_000;
        token.mint(holder, due);
        ghost_minted += due;
        PackageMods memory none;
        _activateSigned(t, 0, address(0), none, false);
    }

    function withdraw(uint8 who) external count("withdraw") {
        address a = who % 2 == 0 ? holder : provider;
        if (token.rejecting(a)) return;
        vm.prank(a);
        escrow.withdraw(address(token));
    }

    function sweep() external count("sweep") {
        escrow.sweepFees(address(token));
    }

    function toggleReject(uint8 who, bool on) external count("toggleReject") {
        address a = who % 2 == 0 ? holder : provider;
        token.setRejecting(a, on);
    }
}

contract EscrowCoreInvariantTest is Test {
    Escrow internal escrow;
    ToggleRejectToken internal token;
    CoreHandler internal h;

    /// The kernel under test. Fee-free here; `EscrowCoreFeeInvariantTest` runs every invariant again on a
    /// kernel that charges its own fee.
    function _kernel() internal virtual returns (Escrow) {
        return new Escrow(address(0), 0, 0);
    }

    function setUp() public {
        token = new ToggleRejectToken();
        escrow = _kernel();
        h = new CoreHandler(escrow, token);
        vm.prank(h.holder());
        token.approve(address(escrow), type(uint256).max);

        bytes4[] memory sel = new bytes4[](16);
        sel[0] = CoreHandler.activate.selector;
        sel[1] = HandlerBase.markFiat.selector;
        sel[2] = HandlerBase.cancelByProvider.selector;
        sel[3] = HandlerBase.timeoutFiat.selector;
        sel[4] = HandlerBase.release.selector;
        sel[5] = HandlerBase.claim.selector;
        sel[6] = HandlerBase.openDisputed.selector;
        sel[7] = HandlerBase.forceDisputeTimeout.selector;
        sel[8] = HandlerBase.mutualCancel.selector;
        sel[9] = HandlerBase.coSignedRelease.selector;
        sel[10] = HandlerBase.mutualSplit.selector;
        sel[11] = CoreHandler.withdraw.selector;
        sel[12] = CoreHandler.toggleReject.selector;
        sel[13] = HandlerBase.warp.selector;
        sel[14] = CoreHandler.activate.selector; // weight activation so the book fills
        sel[15] = CoreHandler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// Escrow holds exactly the live principal, every matured credit and the kernel fees not yet swept.
    /// Nothing more, nothing less.
    function invariant_solvency() public view {
        uint256 live;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            if (!_terminal(escrow.status(id))) live += h.ghostOf(id).principal;
        }
        uint256 credits = escrow.creditOf(address(token), h.holder()) + escrow.creditOf(address(token), h.provider());
        assertEq(
            token.balanceOf(address(escrow)),
            live + credits + escrow.feesOwed(address(token)),
            "escrow balance != live principal + credits + fees owed"
        );
    }

    /// Core-only: every terminal splits the whole principal between Holder and Provider, less the kernel's
    /// completion share when the Provider is paid — except a deadlock, which burns it (Anexo R, 2026-09-24):
    /// Core has no tribunal, so every Core STALEMATE is one, and it pays neither side a wei, nor the DAO.
    /// A refund is never invoiced. No other fee, no dust.
    function invariant_terminalConservation() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
            uint256 principal = h.ghostOf(id).principal;
            if (!_terminal(s)) {
                assertEq(hAmt + pAmt, 0, "live deal has settlement amounts");
                continue;
            }
            if (s == Status.STALEMATE) {
                assertEq(hAmt + pAmt, 0, "a deadlock pays nobody: the principal is burned");
                continue;
            }
            uint256 cut = principal * escrow.completionBps() / 10_000;
            bool invoiced = cut != 0 && hAmt + pAmt + cut == principal;
            assertTrue(hAmt + pAmt == principal || invoiced, "terminal does not conserve principal");
            if (s == Status.CANCELLED) assertEq(hAmt, principal, "cancel not holder-gross");
            if (s == Status.RELEASED) assertEq(pAmt, principal - cut, "release not provider-net");
            if (s == Status.ABANDONED) assertEq(pAmt, principal - cut, "abandoned dispute not provider-net");
            if (s == Status.CLAIMED) assertEq(pAmt, principal - cut, "claim not provider-net");
        }
    }

    /// CASE-CORE-17: once terminal, status and amounts never move again.
    function invariant_terminalImmutable() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            HandlerBase.Ghost memory g = h.ghostOf(id);
            if (!g.terminal) continue;
            (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
            assertEq(uint8(s), uint8(g.terminalStatus), "terminal status mutated");
            assertEq(hAmt, g.holderAmt, "holderAmt mutated");
            assertEq(pAmt, g.providerAmt, "providerAmt mutated");
        }
    }

    /// One nonce, one fill: every activation nonce is consumed and points back to its deal.
    function invariant_nonceBinding() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            HandlerBase.Ghost memory g = h.ghostOf(id);
            assertTrue(escrow.used(h.holder(), g.holderNonce), "holder nonce not consumed");
            assertTrue(escrow.used(h.provider(), g.providerNonce), "provider nonce not consumed");
            assertEq(escrow.dealOf(h.holder(), g.holderNonce), id, "holder dealOf mismatch");
            assertEq(escrow.dealOf(h.provider(), g.providerNonce), id, "provider dealOf mismatch");
            if (g.distinct) {
                assertTrue(escrow.used(h.controller(), g.controllerNonce), "controller nonce not consumed");
                assertEq(escrow.dealOf(h.controller(), g.controllerNonce), id, "controller dealOf mismatch");
            }
        }
    }

    /// Clock origins are written once, in order, and only for the states that own them.
    function invariant_clocksMonotone() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            Status s = escrow.status(id);
            (uint256 activatedAt, uint256 fiatSentAt, uint256 disputedAt, uint256 arbAt) = _clocks(id);
            assertGt(activatedAt, 0, "activatedAt unset");
            assertEq(arbAt, 0, "core deal entered arbitration");
            if (s == Status.FUNDED) {
                assertEq(fiatSentAt, 0, "FUNDED with fiatSentAt");
                assertEq(disputedAt, 0, "FUNDED with disputedAt");
            }
            if (fiatSentAt != 0) assertGe(fiatSentAt, activatedAt, "fiatSentAt before activation");
            if (disputedAt != 0) assertGe(disputedAt, fiatSentAt, "disputedAt before fiatSentAt");
            if (s == Status.DISPUTED) assertGt(disputedAt, 0, "DISPUTED without origin");
        }
    }

    /// Core moves no value to anyone but Holder, Provider and the escrow itself.
    function invariant_noLeak() public view {
        // `0xdEaD` is inside the accounting on purpose: a deadlocked principal goes there, and burning is
        // leaving the recinto to nobody — not leaking to somebody.
        uint256 total = token.balanceOf(address(escrow)) + token.balanceOf(h.holder()) + token.balanceOf(h.provider())
            + token.balanceOf(h.controller()) + token.balanceOf(h.relayer())
            + token.balanceOf(0x000000000000000000000000000000000000dEaD) + _recipientBalance();
        assertEq(total, h.ghost_minted(), "tokens leaked outside the recinto");
        assertEq(token.balanceOf(h.controller()), 0, "controller received principal");
        assertEq(token.balanceOf(h.relayer()), 0, "relayer received principal");
    }

    /// What reached the fee recipient through `sweepFees` — the only party outside the deal Core may pay.
    function _recipientBalance() internal view returns (uint256) {
        address to = escrow.feeRecipient();
        return to == address(0) ? 0 : token.balanceOf(to);
    }

    function _clocks(bytes32 id) internal view returns (uint256, uint256, uint256, uint256) {
        DealClocks memory c = escrow.clocks(id);
        return (c.activatedAt, c.fiatSentAt, c.disputedAt, c.arbitrationOpenedAt);
    }

    function _terminal(Status s) internal pure returns (bool) {
        return s == Status.ABANDONED || s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE
            || s == Status.CANCELLED || s == Status.RESOLVED_BY_ARBITRATION || s == Status.CLAIMED;
    }
}

/// Every Core invariant again, on a kernel that charges the official 0.3% + 0.3% to the DAO (Anexo R, 2026-10-02).
contract EscrowCoreFeeInvariantTest is EscrowCoreInvariantTest {
    function _kernel() internal override returns (Escrow) {
        return new Escrow(address(0xDA0), 30, 30);
    }
}
