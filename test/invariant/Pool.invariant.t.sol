// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {
    Status,
    PackageMods,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualSplit,
    CoSignedRelease,
    isTerminal
} from "../../src/libraries/Types.sol";
import {Consent} from "../../src/libraries/Consent.sol";
import {Escrow} from "../../src/Escrow.sol";
import {TestToken} from "../../mocks/TestToken.sol";
import {Pool} from "../../src/pools/Pool.sol";
import {PoolFactory} from "../../src/pools/PoolFactory.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @dev Open share vault as Holder. LPs deposit/redeem, a designated Controller authorizes and runs deals,
///      the Sponsor toggles runoff. Every escrow verb reaches the pool only through EIP-1271 + pull and
///      `settlementOf`. Ghost books let the test re-derive NAV and the exact allowance from first principles.
contract PoolHandler is HandlerBase {
    uint256 internal constant MAX_DEPOSIT = 5_000_000e6;
    uint256 internal constant MIN_DEPOSIT = 1e6;
    uint256 internal constant MAX_PRINCIPAL = 500_000e6;

    /// Core-only package slots. The handler never authorizes a packaged deal, and `Packages.resolve` now
    /// rejects an all-zero `PackageMods` against any signed id, so this cannot silently under-reserve.
    function _noMods() internal pure returns (PackageMods memory m) {}

    TestToken public token;
    Pool public pool;
    address public sponsor = address(0x5B);
    address[3] public lps = [address(0x11), address(0x12), address(0x13)];

    struct Auth {
        uint256 nonce;
        DealTerms terms;
        uint256 deadline;
        bytes32 dealId; // 0 until activated
        bool unlocked;
        bool reconciled;
    }

    Auth[] internal auths;
    uint256 public ghost_deposited;
    uint256 public ghost_redeemed;

    constructor(Escrow escrow_, TestToken token_, Pool pool_) HandlerBase(escrow_) {
        token = token_;
        pool = pool_;
    }

    function authsLength() external view returns (uint256) {
        return auths.length;
    }

    function authAt(uint256 i) external view returns (Auth memory) {
        return auths[i];
    }

    // --- LP side ---------------------------------------------------------------------------------

    function deposit(uint8 who, uint256 amount) external count("deposit") {
        Pool.Life life = pool.life();
        if (life != Pool.Life.ACTIVE && life != Pool.Life.DEFICIENT) return;
        if (pool.totalShares() != 0 && pool.nav() == 0) return; // vault fully consumed: ZeroNav by design
        if (pool.fightInFlight()) return; // frozen while a deal is in a fight (evaluation of 2026-09-28)
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
        address lp = lps[who % 3];
        token.mint(lp, amount);
        ghost_minted += amount;
        ghost_deposited += amount;
        vm.startPrank(lp);
        token.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function redeem(uint8 who, uint256 sharesIn) external count("redeem") {
        Pool.Life life = pool.life();
        if (life != Pool.Life.ACTIVE && life != Pool.Life.RUNOFF && life != Pool.Life.WINDING_DOWN) return;
        if (pool.fightInFlight()) return;
        address lp = lps[who % 3];
        uint256 have = pool.sharesOf(lp);
        if (have == 0) return;
        sharesIn = bound(sharesIn, 1, have);
        uint256 n = pool.nav();
        uint256 out = sharesIn * n / pool.totalShares();
        if (out > pool.idle()) return;
        if (out == 0 && n != 0) return;
        uint256 before = token.balanceOf(lp);
        vm.prank(lp);
        pool.redeem(sharesIn);
        ghost_redeemed += token.balanceOf(lp) - before;
    }

    // --- Sponsor side ----------------------------------------------------------------------------

    function startRunoff(uint256 seed) external count("startRunoff") {
        if (seed % 16 != 0) return; // RUNOFF freezes deposits and auths; keep it rare so the book keeps moving
        Pool.Life life = pool.life();
        if (life != Pool.Life.ACTIVE && life != Pool.Life.DEFICIENT) return;
        vm.prank(sponsor);
        pool.startRunoff();
    }

    /// `locked == 0` is guaranteed once every auth is unlocked or reconciled (fees sit in locked until reconcile).
    function endRunoff() external count("endRunoff") {
        if (pool.life() != Pool.Life.RUNOFF || pool.totalShares() == 0) return;
        for (uint256 i; i < auths.length; i++) {
            if (!auths[i].unlocked && !auths[i].reconciled) return;
        }
        vm.prank(sponsor);
        pool.endRunoff();
    }

    function setControllerFeeBps(uint16 bps) external count("setControllerFeeBps") {
        vm.prank(sponsor);
        pool.setControllerFeeBps(uint16(bound(bps, 0, 500)));
    }

    function sync() external count("sync") {
        pool.sync();
    }

    // --- Controller side (kernel border) --------------------------------------------------------

    function authorize(uint256 principal, uint256 fiatDur, uint256 relDur, uint256 dispDur)
        external
        count("authorize")
    {
        if (pool.life() != Pool.Life.ACTIVE) return;
        principal = bound(principal, 1, MAX_PRINCIPAL);
        uint256 fee = principal * pool.controllerFeeBps() / 10_000;
        if (pool.idle() < principal + fee) return;
        DealTerms memory t = _baseTerms(principal, true, fiatDur, relDur, dispDur);
        t.holder = address(pool);
        t.token = address(token);
        uint256 n = ++nonce;
        uint256 deadline = block.timestamp + AUTH_TTL;
        HolderAuthorization memory ha = HolderAuthorization({terms: t, nonce: n, deadline: deadline});
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        auths.push(
            Auth({nonce: n, terms: t, deadline: deadline, dealId: bytes32(0), unlocked: false, reconciled: false})
        );
    }

    function activate(uint256 seed) external count("activate") {
        (uint256 i, bool ok) = _pickAuth(seed, _canActivate);
        if (!ok) return;
        Auth storage a = auths[i];
        HolderAuthorization memory ha = HolderAuthorization({terms: a.terms, nonce: a.nonce, deadline: a.deadline});
        uint256 pN = ++nonce;
        uint256 cN = ++nonce;
        ProviderAgreement memory pa =
            ProviderAgreement({terms: a.terms, nonce: pN, deadline: block.timestamp + AUTH_TTL});
        ControllerAcceptance memory ca =
            ControllerAcceptance({terms: a.terms, nonce: cN, deadline: block.timestamp + AUTH_TTL});
        vm.prank(relayer);
        bytes32 id = escrow.activate(
            ha,
            "",
            pa,
            _sign(PROVIDER_PK, Consent.hashProviderAgreement(pa)),
            ca,
            _sign(CONTROLLER_PK, Consent.hashControllerAcceptance(ca))
        );
        a.dealId = id;
        _record(id, a.terms, a.nonce, pN, cN, 0, address(0));
    }

    function unlock(uint256 seed) external count("unlock") {
        (uint256 i, bool ok) = _pickAuth(seed, _canUnlock);
        if (!ok) return;
        pool.unlock(auths[i].nonce);
        auths[i].unlocked = true;
    }

    function reconcile(uint256 seed) external count("reconcile") {
        (uint256 i, bool ok) = _pickAuth(seed, _canReconcile);
        if (!ok) return;
        Auth storage a = auths[i];
        pool.reconcile(a.nonce);
        a.reconciled = true;
    }

    function controllerWithdraw() external count("controllerWithdraw") {
        vm.prank(controller);
        pool.withdrawCredit();
    }

    // --- predicates over auths ------------------------------------------------------------------

    function _canActivate(uint256 i) internal view returns (bool) {
        Auth storage a = auths[i];
        return a.dealId == bytes32(0) && !a.unlocked && block.timestamp <= a.deadline && pool.life() == Pool.Life.ACTIVE
            && pool.isAgent(a.terms.controller);
    }

    function _canUnlock(uint256 i) internal view returns (bool) {
        Auth storage a = auths[i];
        return
            a.dealId == bytes32(0) && !a.unlocked && (block.timestamp > a.deadline || pool.life() != Pool.Life.ACTIVE);
    }

    function _canReconcile(uint256 i) internal view returns (bool) {
        Auth storage a = auths[i];
        return a.dealId != bytes32(0) && !a.reconciled && _isTerminal(escrow.status(a.dealId));
    }

    function _pickAuth(uint256 seed, function(uint256) internal view returns (bool) pred)
        internal
        view
        returns (uint256 i, bool ok)
    {
        uint256 n = auths.length;
        if (n == 0) return (0, false);
        uint256 start = seed % n;
        for (uint256 k; k < n; k++) {
            uint256 c = (start + k) % n;
            if (pred(c)) return (c, true);
        }
    }

    // --- derived books (mirror of Pool._books from the ghost side) -------------------------------

    /// Sum of principal in escrow for activated, non-terminal deals: the receivable the pool cannot touch.
    function receivable() public view returns (uint256 r) {
        for (uint256 i; i < auths.length; i++) {
            Auth storage a = auths[i];
            if (a.dealId == bytes32(0)) continue;
            if (!_isTerminal(escrow.status(a.dealId))) r += a.terms.principal;
        }
    }

    /// Loss already realized on-chain but not yet flushed by `reconcile`: (principal - returned) of terminal deals.
    function pendingConsumed() public view returns (uint256 c) {
        for (uint256 i; i < auths.length; i++) {
            Auth storage a = auths[i];
            if (a.dealId == bytes32(0) || a.reconciled) continue;
            (Status s, uint256 returned,) = escrow.settlementOf(a.dealId);
            if (_isTerminal(s)) c += a.terms.principal - returned;
        }
    }

    /// Exact allowance the pool must hold toward the escrow: principal of auths that are still pullable.
    function pullable() public view returns (uint256 lo, uint256 hi) {
        for (uint256 i; i < auths.length; i++) {
            Auth storage a = auths[i];
            if (a.unlocked || a.reconciled) continue;
            hi += a.terms.principal;
            if (a.dealId == bytes32(0)) lo += a.terms.principal;
        }
    }
}

contract PoolInvariantTest is Test {
    Escrow internal escrow;
    TestToken internal token;
    PoolFactory internal factory;
    Pool internal pool;
    PoolHandler internal h;

    function setUp() public {
        token = new TestToken();
        escrow = new Escrow(address(0), 0, 0);
        factory = new PoolFactory(address(escrow));
        address sponsor = address(0x5B);
        address ctrl = vm.addr(0xC0);
        address[] memory sps = new address[](1);
        sps[0] = sponsor;
        address[] memory cs = new address[](1);
        cs[0] = ctrl;
        address[] memory none = new address[](0);
        pool = Pool(factory.createPool(sps, address(token), cs, true, none, 100));
        h = new PoolHandler(escrow, token, pool);

        bytes4[] memory sel = new bytes4[](26);
        sel[22] = HandlerBase.openDisputed.selector;
        sel[23] = HandlerBase.forceDisputeTimeout.selector;
        sel[24] = HandlerBase.mutualCancel.selector;
        sel[25] = HandlerBase.coSignedRelease.selector;
        sel[0] = PoolHandler.deposit.selector;
        sel[1] = PoolHandler.deposit.selector;
        sel[2] = PoolHandler.redeem.selector;
        sel[3] = PoolHandler.authorize.selector;
        sel[4] = PoolHandler.authorize.selector;
        sel[5] = PoolHandler.activate.selector;
        sel[6] = PoolHandler.activate.selector;
        sel[7] = PoolHandler.unlock.selector;
        sel[8] = PoolHandler.reconcile.selector;
        sel[9] = PoolHandler.reconcile.selector;
        sel[10] = PoolHandler.sync.selector;
        sel[11] = PoolHandler.startRunoff.selector;
        sel[12] = PoolHandler.endRunoff.selector;
        sel[13] = PoolHandler.setControllerFeeBps.selector;
        sel[14] = PoolHandler.controllerWithdraw.selector;
        sel[15] = HandlerBase.markFiat.selector;
        sel[16] = HandlerBase.release.selector;
        sel[17] = HandlerBase.cancelByProvider.selector;
        sel[18] = HandlerBase.timeoutFiat.selector;
        sel[19] = HandlerBase.claim.selector;
        sel[20] = HandlerBase.mutualSplit.selector;
        sel[21] = HandlerBase.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// Shares are fully accounted: totalShares == sum over LPs.
    function invariant_shares() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            sum += pool.sharesOf(h.lps(i));
        }
        assertEq(pool.totalShares(), sum, "totalShares != sum of LP shares");
    }

    /// On-hand assets (balance + matured escrow credit) == NAV minus principal still in escrow,
    /// plus any Controller fee credited but not yet pushed. `nav()` previews terminals the vault has not flushed.
    function invariant_books() public view {
        uint256 onHand = token.balanceOf(address(pool)) + escrow.creditOf(address(token), address(pool));
        uint256 expected = pool.nav() - h.receivable() + pool.controllerCredit(h.controller());
        assertEq(onHand, expected, "pool on-hand != nav - receivable");
        assertLe(pool.idle(), token.balanceOf(address(pool)), "idle exceeds balance");
    }

    /// NAV moves only by deposits, redemptions and consumption (provider-positive principal, Controller fees).
    function invariant_navConservation() public view {
        uint256 expected = h.ghost_deposited() - h.ghost_redeemed() - pool.consumed() - h.pendingConsumed();
        assertEq(pool.nav(), expected, "nav != deposits - redemptions - consumed");
    }

    /// Approve is exact, never max: bounded by the principal of auths still pullable by the escrow.
    /// Between escrow activation and the next pool touch the pool may not have noticed a fill (upper bound).
    function invariant_allowanceExact() public view {
        uint256 allowance = token.allowance(address(pool), address(escrow));
        (uint256 lo, uint256 hi) = h.pullable();
        assertGe(allowance, lo, "allowance below pullable principal");
        assertLe(allowance, hi, "allowance above outstanding auths");
        assertTrue(allowance != type(uint256).max, "infinite allowance");
    }

    /// Honest counterparties never push the vault into DEFICIENT; CLOSED only with zero shares and zero locked.
    function invariant_life() public view {
        Pool.Life life = pool.life();
        assertTrue(life != Pool.Life.DEFICIENT && life != Pool.Life.WINDING_DOWN, "unexpected life");
        if (life == Pool.Life.CLOSED) {
            assertEq(pool.totalShares(), 0, "CLOSED with shares");
            assertEq(pool.locked(), 0, "CLOSED with locked");
        }
    }

    /// The pool is the Holder: holder-gross comes back to the pool, never to the Controller or an LP.
    function invariant_holderGrossToPool() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            DealTerms memory t = escrow.terms(id);
            assertEq(t.holder, address(pool), "pool deal holder != pool");
            assertEq(t.controller, h.controller(), "controller drifted");
        }
        // Controller only ever receives its fee through the pool's payables, never from the escrow.
        assertEq(escrow.creditOf(address(token), h.controller()), 0, "escrow credited the controller");
    }

    function afterInvariant() public view {
        uint256 live;
        uint256 term;
        for (uint256 i; i < h.idsLength(); i++) {
            Status s = escrow.status(h.ids(i));
            if (isTerminal(s)) {
                term++;
            } else {
                live++;
            }
        }
        console2.log("auths/deals live/terminal", h.authsLength(), live, term);
        console2.log("nav/idle/consumed", pool.nav(), pool.idle(), pool.consumed());
        console2.log("life/controllerBal", uint8(pool.life()), token.balanceOf(h.controller()));
    }
}
