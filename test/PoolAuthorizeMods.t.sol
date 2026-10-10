// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Escrow} from "../src/Escrow.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev `Pool.authorize` used to take a bare `reputation` address and quietly reserve no activation fee when
///      it was zero, which let a REPUTATION deal drain the vault without any book recording it. It now takes
///      the full `PackageMods` and runs the kernel's own `Packages.resolve` before reserving anything, so a
///      deal cannot be authorized with less than it carries. These tests pin that guarantee and the two
///      consequences that matter: the aggregate allowance always covers every reservation, and the only way
///      to reserve a zero activation fee for a REPUTATION deal is for the module to genuinely charge none.
contract PoolAuthorizeModsTest is BaseTest {
    uint256 internal constant ACT_BPS = 1_000;
    uint256 internal constant ACT_FEE = PRINCIPAL * ACT_BPS / 10_000;
    bytes32 internal constant SUB_POOL = keccak256("pool");
    bytes32 internal constant SUB_PROV = keccak256("prov");

    PoolFactory internal factory;
    Pool internal pool;
    PassportMock internal passport;
    Reputation internal rep;
    address internal feeRecipient = address(0xFEE);
    address internal lp1 = address(0x11);
    address internal lp2 = address(0x22);

    /// Two LPs fund exactly two priced authorizations, so the allowance arithmetic is tight and any
    /// under-reservation shows up immediately.
    uint256 internal constant LP_DEPOSIT = PRINCIPAL + ACT_FEE;

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory(address(escrow));
        passport = new PassportMock();
        rep = new Reputation(passport, feeRecipient, ACT_BPS, 0, 0, 0, address(escrow));

        address[] memory sponsors = new address[](1);
        sponsors[0] = holder;
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        pool = Pool(factory.createPool(sponsors, address(token), controllers, true, new address[](0), 0));
        vm.prank(controller);
        pool.setOperatorTag(bytes32(uint256(1))); // Anexo R, 2026-10-05: the Controller acts as a registered operator

        passport.setHuman(address(pool), SUB_POOL);
        passport.setHuman(provider, SUB_PROV);

        _deposit(lp1, LP_DEPOSIT);
        _deposit(lp2, LP_DEPOSIT);
    }

    // --- instrumentation ------------------------------------------------------------------------

    /// Real backing the pool can actually pay out: its own balance plus whatever the escrow owes it.
    function _onHand() internal view returns (uint256) {
        return IERC20(address(token)).balanceOf(address(pool)) + escrow.creditOf(address(token), address(pool));
    }

    function _report(string memory tag) internal view {
        console.log("--- %s", tag);
        console.log("  idle      ", pool.idle());
        console.log("  locked    ", pool.locked());
        console.log("  credits   ", pool.credits());
        console.log("  consumed  ", pool.consumed());
        console.log("  nav()     ", pool.nav());
        console.log("  onHand    ", _onHand());
        console.log("  life      ", uint8(pool.life()));
        console.log("  allowance ", IERC20(address(token)).allowance(address(pool), address(escrow)));
        console.log("  feeRecip  ", IERC20(address(token)).balanceOf(feeRecipient));
    }

    // --- scenario --------------------------------------------------------------------------------

    function _repTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
        t.packageIds = _sorted2(passport.packageId(), rep.packageId());
    }

    function _repAuth(uint256 nonce) internal view returns (HolderAuthorization memory ha) {
        ha = _holderAuth(_repTerms(), nonce);
    }

    function _repMods() internal view returns (PackageMods memory m) {
        m.passport = address(passport);
        m.reputation = address(rep);
    }

    function _activate(HolderAuthorization memory ha, PackageMods memory mods, uint256 pNonce, uint256 cNonce)
        internal
        returns (bytes32)
    {
        ProviderAgreement memory pa = _providerAuth(ha.terms, pNonce);
        ControllerAcceptance memory ca = _controllerAuth(ha.terms, cNonce);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca), mods);
    }

    // --- tests ------------------------------------------------------------------------------------

    /// The correct path, end to end: reserve, activate, book, reconcile. nav() tracks real backing at every
    /// step and the fee lands in `consumed` rather than vanishing.
    function test_pricedAuthorization_booksTheFee() public {
        HolderAuthorization memory ha = _repAuth(1);
        vm.prank(controller);
        pool.authorize(ha, _repMods());
        _report("after one priced authorization");
        assertEq(pool.idle(), LP_DEPOSIT * 2 - PRINCIPAL - ACT_FEE);
        assertEq(pool.locked(), PRINCIPAL + ACT_FEE);
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), PRINCIPAL + ACT_FEE);

        bytes32 id = _activate(ha, _repMods(), 1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(IERC20(address(token)).balanceOf(feeRecipient), ACT_FEE);
        // `activate` never calls back into the pool, so nothing is booked yet; `_books()` already nets the
        // fee out of the projection for any auth whose deal exists, so nav() is correct immediately.
        assertEq(pool.consumed(), 0, "activate does not book anything");
        assertEq(pool.nav(), _onHand() + PRINCIPAL, "nav == onHand + principal held by the escrow");

        pool.sync();
        _report("after sync");
        assertEq(pool.consumed(), ACT_FEE, "the next pool verb books the fee");
        assertEq(pool.nav(), _onHand() + PRINCIPAL, "still reconciled");
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    /// The state that used to under-reserve. A deal whose signed ids include REPUTATION cannot be authorized
    /// with that slot empty: `resolve` requires every signed id to be matched to a named module, and it runs
    /// before anything is reserved, so this fails closed with nothing moved.
    function test_authorize_rejectsRepDealWithUnnamedModule() public {
        HolderAuthorization memory ha = _repAuth(1);
        PackageMods memory mods;
        mods.passport = address(passport);
        // mods.reputation deliberately left at zero -- the mistake under test

        uint256 idleBefore = pool.idle();
        vm.prank(controller);
        vm.expectRevert(Packages.UnknownPackage.selector);
        pool.authorize(ha, mods);

        assertEq(pool.locked(), 0, "nothing was reserved");
        assertEq(pool.idle(), idleBefore, "idle untouched");
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), 0, "no allowance granted");
        assertEq(pool.consumed(), 0);
    }

    /// The damage vector was the aggregate allowance: `_refreshApprove` grants one sum over all live auths, so
    /// an auth that reserved no fee could spend another auth's reservation. With every auth priced, the
    /// allowance covers exactly the pulls the kernel will make and both deals activate.
    function test_allowance_coversEveryReservedActivationFee() public {
        HolderAuthorization memory a = _repAuth(1);
        HolderAuthorization memory b = _repAuth(2);
        vm.startPrank(controller);
        pool.authorize(a, _repMods());
        pool.authorize(b, _repMods());
        vm.stopPrank();

        assertEq(pool.idle(), 0, "both reservations exactly consume the float");
        assertEq(pool.locked(), 2 * (PRINCIPAL + ACT_FEE));
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), 2 * (PRINCIPAL + ACT_FEE));

        bytes32 idA = _activate(a, _repMods(), 1, 1);
        assertEq(uint8(escrow.status(idA)), uint8(Status.FUNDED));
        // The second deal still has exactly what it needs: nothing was borrowed from it.
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), PRINCIPAL + ACT_FEE);
        bytes32 idB = _activate(b, _repMods(), 2, 2);
        assertEq(uint8(escrow.status(idB)), uint8(Status.FUNDED));
        assertEq(IERC20(address(token)).balanceOf(feeRecipient), 2 * ACT_FEE, "both fees collected");
        assertEq(pool.nav(), _onHand() + 2 * PRINCIPAL, "nav still tracks real backing");
    }

    /// After `resolve` gates `authorize`, reserving a zero activation fee for a REPUTATION deal is only
    /// possible when the module genuinely charges zero -- and then the kernel pulls zero too. That is what
    /// makes the rebooking branch in `_recognizeLive` unreachable rather than merely rare: a nonzero pull
    /// always implies a nonzero reservation.
    function test_zeroFeeModule_reservesZeroAndPullsZero() public {
        Reputation free = new Reputation(passport, feeRecipient, 0, 0, 0, 0, address(escrow));
        DealTerms memory t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
        t.packageIds = _sorted2(passport.packageId(), free.packageId());
        HolderAuthorization memory ha = _holderAuth(t, 1);
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(free);

        vm.prank(controller);
        pool.authorize(ha, mods);
        assertEq(pool.locked(), PRINCIPAL, "no activation fee to reserve");
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), PRINCIPAL);

        bytes32 id = _activate(ha, mods, 1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(IERC20(address(token)).balanceOf(feeRecipient), 0, "the kernel pulled nothing either");

        pool.sync();
        assertEq(pool.consumed(), 0, "so there is nothing to book");
        assertEq(pool.nav(), _onHand() + PRINCIPAL, "books reconcile without any repair");
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    // --- helpers ----------------------------------------------------------------------------------

    function _deposit(address lp, uint256 amount) internal {
        token.mint(lp, amount);
        vm.startPrank(lp);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _sorted2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        if (uint256(a) < uint256(b)) {
            ids[0] = a;
            ids[1] = b;
        } else {
            ids[0] = b;
            ids[1] = a;
        }
    }
}
