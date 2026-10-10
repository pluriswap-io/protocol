// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualSplit,
    PackageMods
} from "../src/libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Escrow} from "../src/Escrow.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BaseTest} from "./Base.t.sol";
import {RailKeysHarness} from "./RailKeys.t.sol";
import {PinnedAnchors} from "../src/packages/adapters/PinnedAnchors.sol";
import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";

contract PoolTest is BaseTest {
    PoolFactory internal factory;
    Pool internal pool;

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory(address(escrow));
        pool = _privatePool(0);
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();
    }

    function test_private_onlyDepositors() public {
        address outsider = address(0xBEEF);
        token.mint(outsider, PRINCIPAL);
        vm.startPrank(outsider);
        token.approve(address(pool), PRINCIPAL);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();
    }

    function test_private_sponsorNotDepositorCannotDeposit() public {
        address extraSponsor = address(0x51);
        address[] memory sps = new address[](2);
        sps[0] = holder;
        sps[1] = extraSponsor;
        address[] memory cs = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        Pool p = Pool(factory.createPool(sps, address(token), cs, false, deps, 0));
        token.mint(extraSponsor, PRINCIPAL);
        vm.startPrank(extraSponsor);
        token.approve(address(p), PRINCIPAL);
        vm.expectRevert(Pool.Unauthorized.selector);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertTrue(p.isAgent(extraSponsor));
    }

    function test_open_anyoneDeposits() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), none, true, none, 0));
        address lp = address(0x11);
        token.mint(lp, PRINCIPAL);
        vm.startPrank(lp);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertEq(p.sharesOf(lp), PRINCIPAL);
        assertEq(p.idle(), PRINCIPAL);
    }

    function test_secondMint_proportionalToNav() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), none, true, none, 0));
        token.mint(holder, PRINCIPAL * 2);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertEq(p.sharesOf(holder), PRINCIPAL * 2);
        assertEq(p.totalShares(), PRINCIPAL * 2);
    }

    function test_redeem_burnsShares() public {
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        assertEq(pool.sharesOf(holder), 0);
        assertEq(pool.idle(), 0);
        assertEq(token.balanceOf(holder), before + PRINCIPAL);
    }

    function test_firstDeposit_floor() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), none, true, none, 0));
        token.mint(holder, 1);
        vm.startPrank(holder);
        token.approve(address(p), 1);
        vm.expectRevert(Pool.FirstDepositTooSmall.selector);
        p.deposit(1);
        vm.stopPrank();
    }

    function test_setController_cannotUnsetSponsor() public {
        vm.prank(holder);
        vm.expectRevert(Pool.IsSponsor.selector);
        pool.setController(holder, false);
        assertTrue(pool.isAgent(holder));
    }

    function test_designated_isAgent_lpIsNot() public {
        address lp = address(0x11);
        assertTrue(pool.isAgent(controller));
        assertFalse(pool.isAgent(lp));
        vm.prank(holder);
        pool.setController(lp, true);
        assertTrue(pool.isAgent(lp));
    }

    function test_deficient_recap() public {
        deal(address(token), address(pool), 0);
        pool.sync();
        assertEq(uint8(pool.life()), uint8(Pool.Life.DEFICIENT));
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_authorize_activateSameTypedData() public {
        bytes32 id = _activatePool(1, 1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.nav(), PRINCIPAL);
        assertTrue(escrow.used(address(pool), 1));
    }

    function test_authorize_rejectsUnknownController() public {
        DealTerms memory terms = _poolHolderTerms();
        terms.controller = address(0xBEEF);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.authorize(ha, _noMods());
    }

    function test_authorize_rejectsWhenIdleShort() public {
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(ha, _noMods());
    }

    function test_authorize_sponsorCanBeController() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        Pool p = Pool(factory.createPool(sps, address(token), none, false, deps, 0));
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = holder;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(holder);
        p.authorize(ha, _noMods());
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signHolderAsController(ca));
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_twoConcurrentDealsDoNotOverAllocate() public {
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);

        _activatePool(1, 1, 1);
        _activatePool(2, 2, 2);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), PRINCIPAL * 2);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL * 2);

        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 3);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(ha, _noMods());
    }

    function test_kickController_pendingAuth_1271Rejects() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        bytes32 digest = _typed(Consent.hashHolderAuthorization(ha));
        assertEq(pool.isValidSignature(digest, ""), bytes4(0x1626ba7e));

        vm.prank(holder);
        pool.setController(controller, false);
        assertEq(pool.isValidSignature(digest, ""), bytes4(0));

        ProviderAgreement memory pa = _providerAuth(_poolHolderTerms(), 1);
        ControllerAcceptance memory ca = _controllerAuth(_poolHolderTerms(), 1);
        bytes memory pSig = _signProvider(pa);
        bytes memory cSig = _signController(ca);
        vm.expectRevert(Escrow.InvalidHolderSignature.selector);
        escrow.activate(ha, "", pa, pSig, ca, cSig);
    }

    function test_runoff_pendingAuth_1271Rejects() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        vm.prank(holder);
        pool.startRunoff();
        assertEq(pool.isValidSignature(_typed(Consent.hashHolderAuthorization(ha)), ""), bytes4(0));
    }

    function test_kickController_futureOnly() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.setController(controller, false);

        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 2);
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.authorize(ha, _noMods());

        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
        assertEq(token.balanceOf(controller), 0);
    }

    function test_unlock_afterDeadlineIfNonceUnused() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        assertEq(pool.locked(), PRINCIPAL);

        vm.expectRevert(Pool.DeadlineActive.selector);
        pool.unlock(1);

        vm.warp(ha.deadline + 1);
        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
        assertEq(pool.isValidSignature(_typed(Consent.hashHolderAuthorization(ha)), ""), bytes4(0));
    }

    function test_kick_unlocksBeforeDeadline() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        vm.prank(holder);
        pool.setController(controller, false);

        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
    }

    function test_runoff_unlocksBeforeDeadline() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        vm.prank(holder);
        pool.startRunoff();

        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
    }

    function test_unlock_revertsIfActivated() public {
        _activatePool(1, 1, 1);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Pool.NonceConsumed.selector);
        pool.unlock(1);
    }

    function test_reconcile_cancelReturnsIdle() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        pool.reconcile(1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
        assertEq(pool.consumed(), 0);
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_reconcile_releaseConsumes() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), 0);
        assertEq(pool.consumed(), PRINCIPAL);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_fee_reservedAndPaidOnRelease() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        assertEq(p.locked(), PRINCIPAL + fee);
        assertEq(p.idle(), 0);
        assertEq(token.balanceOf(address(p)), PRINCIPAL + fee);

        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(token.balanceOf(address(p)), fee);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1);
        assertEq(p.consumed(), PRINCIPAL + fee);
        assertEq(p.idle(), 0);
        assertEq(token.balanceOf(controller), fee);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_fee_returnedOnFullRefund() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        vm.prank(provider);
        escrow.cancelByProvider(id);
        p.reconcile(1);
        assertEq(p.idle(), PRINCIPAL + fee);
        assertEq(p.consumed(), 0);
        assertEq(token.balanceOf(controller), 0);
    }

    function test_feeBpsChange_doesNotAffectOpenAuth() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        vm.prank(holder);
        p.setControllerFeeBps(500);
        vm.warp(ha.deadline + 1);
        p.unlock(1);
        assertEq(p.idle(), PRINCIPAL + fee);
        assertEq(p.locked(), 0);
    }

    function test_windDown_rejectsNewAuthorize() public {
        vm.prank(holder);
        pool.windDown();
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha, _noMods());
    }

    function test_windDown_liveDealThenRedeemCloses() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.windDown();
        vm.prank(holder);
        vm.expectRevert(Pool.RedeemExceedsIdle.selector);
        pool.redeem(PRINCIPAL);

        vm.prank(provider);
        escrow.cancelByProvider(id);
        pool.reconcile(1);
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        assertEq(uint8(pool.life()), uint8(Pool.Life.CLOSED));
    }

    function test_runoff_blocksAuthorize_endRunoffWhenIdle() public {
        vm.prank(holder);
        pool.startRunoff();
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha, _noMods());
        vm.prank(holder);
        pool.endRunoff();
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_redeem_doesNotInvadeLocked() public {
        _activatePool(1, 1, 1);
        vm.prank(holder);
        vm.expectRevert(Pool.RedeemExceedsIdle.selector);
        pool.redeem(PRINCIPAL);
        assertEq(pool.locked(), PRINCIPAL);
    }

    function test_donate_doesNotInflateSharePrice() public {
        Pool p = _openPool(0);
        address attacker = address(0xA77);
        address victim = address(0xB0B1);
        _fundLp(attacker, p, PRINCIPAL);
        token.mint(attacker, PRINCIPAL * 10);
        vm.prank(attacker);
        token.transfer(address(p), PRINCIPAL * 10);
        assertEq(p.nav(), PRINCIPAL);
        assertEq(p.idle(), PRINCIPAL);

        _fundLp(victim, p, PRINCIPAL);
        assertEq(p.sharesOf(victim), PRINCIPAL);
        assertEq(p.sharesOf(attacker), PRINCIPAL);
        assertEq(p.nav(), PRINCIPAL * 2);

        uint256 before = token.balanceOf(victim);
        vm.prank(victim);
        p.redeem(PRINCIPAL);
        assertEq(token.balanceOf(victim), before + PRINCIPAL);
        assertEq(p.nav(), PRINCIPAL);
    }

    function test_deposit_revertsWhenNavZeroAfterTotalConsume() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);
        assertEq(pool.nav(), 0);
        assertTrue(pool.totalShares() > 0);
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        vm.expectRevert(Pool.ZeroNav.selector);
        pool.deposit(PRINCIPAL);

        uint256 shares = pool.sharesOf(holder);
        vm.prank(holder);
        pool.redeem(shares);
        assertEq(pool.sharesOf(holder), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.nav(), 0);

        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        assertEq(pool.sharesOf(holder), PRINCIPAL);
        assertEq(pool.idle(), PRINCIPAL);
    }

    function test_redeem_zeroNavThenClosed() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);

        vm.prank(holder);
        pool.windDown();
        uint256 shares = pool.sharesOf(holder);
        vm.prank(holder);
        pool.redeem(shares);
        assertEq(uint8(pool.life()), uint8(Pool.Life.CLOSED));
        assertEq(pool.totalShares(), 0);
        assertEq(pool.locked(), 0);
    }

    function test_fee_maxBps_controllerTakesPrincipal() public {
        Pool p = _privatePool(10_000);
        token.mint(holder, PRINCIPAL * 2);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL * 2);
        vm.stopPrank();

        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        assertEq(p.locked(), PRINCIPAL * 2);
        assertEq(p.idle(), 0);
        assertEq(token.balanceOf(address(p)), PRINCIPAL);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1);
        assertEq(token.balanceOf(controller), PRINCIPAL);
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(p.consumed(), PRINCIPAL * 2);
        assertEq(p.nav(), 0);
    }

    function test_fee_bpsAboveMaxReverts() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        vm.expectRevert(Pool.BadFee.selector);
        factory.createPool(sps, address(token), none, false, deps, 10_001);

        vm.prank(holder);
        vm.expectRevert(Pool.BadFee.selector);
        pool.setControllerFeeBps(10_001);
    }

    function test_twoSponsors_eitherActs_neitherCanBeKicked() public {
        uint256 extraPk = 0x51;
        address extra = vm.addr(extraPk);
        address[] memory sps = new address[](2);
        sps[0] = holder;
        sps[1] = extra;
        address[] memory none = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        Pool p = Pool(factory.createPool(sps, address(token), none, false, deps, 0));
        assertTrue(p.isAgent(holder));
        assertTrue(p.isAgent(extra));

        address desk = address(0xDE5);
        vm.prank(extra);
        p.setController(desk, true);
        assertTrue(p.isAgent(desk));

        vm.prank(extra);
        vm.expectRevert(Pool.IsSponsor.selector);
        p.setController(holder, false);
        vm.prank(address(0xBEEF));
        vm.expectRevert(Pool.Unauthorized.selector);
        p.setController(desk, false);

        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = extra;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(extra);
        p.authorize(ha, _noMods());
        bytes32 id = escrow.activate(
            ha, "", pa, _signProvider(pa), ca, _sign(_typed(Consent.hashControllerAcceptance(ca)), extraPk)
        );
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_create_duplicateSponsorsReverts() public {
        address[] memory sps = new address[](2);
        sps[0] = holder;
        sps[1] = holder;
        address[] memory none = new address[](0);
        vm.expectRevert(Pool.Duplicate.selector);
        factory.createPool(sps, address(token), none, true, none, 0);
    }

    function test_fee_pushRevert_keepsControllerCredit() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);

        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (controller, fee)), "blocked");
        p.reconcile(1);
        assertEq(p.consumed(), PRINCIPAL + fee);
        assertEq(p.nav(), 0);
        assertEq(token.balanceOf(controller), 0);
        assertEq(p.controllerCredit(controller), fee);
        assertEq(token.balanceOf(address(p)), fee);

        vm.clearMockedCalls();
        vm.prank(controller);
        p.withdrawCredit();
        assertEq(token.balanceOf(controller), fee);
        assertEq(p.controllerCredit(controller), 0);
    }

    function test_reconcile_twiceAndBeforeTerminalRevert() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.expectRevert(Pool.StillLive.selector);
        pool.reconcile(1);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);
        vm.expectRevert(Pool.NoAuth.selector);
        pool.reconcile(1);
    }

    function test_authorize_expiredDeadlineReverts() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.warp(ha.deadline + 1);
        vm.prank(controller);
        vm.expectRevert(Pool.DeadlineActive.selector);
        pool.authorize(ha, _noMods());
    }

    function test_runoff_blocksDeposit_endRunoffWhileLockedReverts() public {
        _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.startRunoff();
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.deposit(PRINCIPAL);
        vm.prank(holder);
        vm.expectRevert(Pool.StillLive.selector);
        pool.endRunoff();
    }

    function test_1271_rejectsUnknownDigest() public view {
        assertEq(pool.isValidSignature(bytes32(uint256(1)), ""), bytes4(0));
    }

    function test_fee_revertsIfIdleShortOfPrincipalPlusFee() public {
        uint16 bps = 100;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        p.authorize(_holderAuth(terms, 1), _noMods());
    }

    function test_fee_zeroBps_controllerUnpaid() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);
        assertEq(pool.controllerFeeBps(), 0);
        assertEq(token.balanceOf(controller), 0);
        assertEq(pool.consumed(), PRINCIPAL);
        assertEq(pool.nav(), 0);
    }

    function test_fee_paidOnSplit() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);

        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory prov = MutualSplit({dealId: id, providerBps: 5000, nonce: 2, deadline: deadline});
        MutualSplit memory ctrl = MutualSplit({dealId: id, providerBps: 5000, nonce: 2, deadline: deadline});
        escrow.mutualSplit(
            prov,
            _sign(_typed(Consent.hashMutualSplit(prov)), providerPk),
            ctrl,
            _sign(_typed(Consent.hashMutualSplit(ctrl)), controllerPk)
        );

        (Status st, uint256 returned,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_SPLIT));
        assertEq(returned, PRINCIPAL / 2);
        assertTrue(returned < PRINCIPAL);

        p.reconcile(1);
        assertEq(p.consumed(), PRINCIPAL - returned + fee);
        assertEq(p.idle(), returned);
        assertEq(p.nav(), returned);
        assertEq(token.balanceOf(controller), fee);
        assertEq(token.balanceOf(provider), PRINCIPAL - returned);
    }

    function test_nav_twoLpsAfterConsume() public {
        Pool p = _openPool(0);
        address lpA = address(0xA1);
        address lpB = address(0xB1);
        _fundLp(lpA, p, PRINCIPAL * 2);
        assertEq(p.nav(), PRINCIPAL * 2);
        assertEq(p.sharesOf(lpA), PRINCIPAL * 2);
        assertEq(p.idle(), PRINCIPAL * 2);

        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        assertEq(p.nav(), PRINCIPAL * 2);
        assertEq(p.idle(), PRINCIPAL);
        assertEq(p.locked(), PRINCIPAL);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1);

        assertEq(p.idle(), PRINCIPAL);
        assertEq(p.locked(), 0);
        assertEq(p.consumed(), PRINCIPAL);
        assertEq(p.nav(), PRINCIPAL);
        assertEq(p.totalShares(), PRINCIPAL * 2);

        _fundLp(lpB, p, PRINCIPAL);
        assertEq(p.sharesOf(lpB), PRINCIPAL * 2);
        assertEq(p.totalShares(), PRINCIPAL * 4);
        assertEq(p.nav(), PRINCIPAL * 2);

        uint256 before = token.balanceOf(lpA);
        vm.prank(lpA);
        p.redeem(PRINCIPAL);
        assertEq(token.balanceOf(lpA), before + PRINCIPAL / 2);
        assertEq(p.sharesOf(lpA), PRINCIPAL);
        assertEq(p.nav(), PRINCIPAL * 2 - PRINCIPAL / 2);
        assertEq(p.idle(), PRINCIPAL * 2 - PRINCIPAL / 2);
    }

    function test_open_fee_twoLps() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _openPool(bps);
        address lpA = address(0xA2);
        address lpB = address(0xB2);
        _fundLp(lpA, p, PRINCIPAL * 2);
        _fundLp(lpB, p, PRINCIPAL);
        assertEq(p.nav(), PRINCIPAL * 3);
        assertEq(p.sharesOf(lpA), PRINCIPAL * 2);
        assertEq(p.sharesOf(lpB), PRINCIPAL);

        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        assertEq(p.locked(), PRINCIPAL + fee);
        assertEq(p.idle(), PRINCIPAL * 3 - PRINCIPAL - fee);
        assertEq(p.nav(), PRINCIPAL * 3);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1);

        assertEq(token.balanceOf(controller), fee);
        assertEq(p.consumed(), PRINCIPAL + fee);
        assertEq(p.locked(), 0);
        assertEq(p.nav(), PRINCIPAL * 3 - PRINCIPAL - fee);
        assertEq(p.idle(), p.nav());
        assertEq(p.totalShares(), PRINCIPAL * 3);
    }

    function test_redeem_partialWhileLocked() public {
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        assertEq(pool.nav(), PRINCIPAL * 2);

        _activatePool(1, 1, 1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.nav(), PRINCIPAL * 2);

        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        pool.redeem(PRINCIPAL / 2);
        assertEq(token.balanceOf(holder), before + PRINCIPAL / 2);
        assertEq(pool.sharesOf(holder), PRINCIPAL * 2 - PRINCIPAL / 2);
        assertEq(pool.idle(), PRINCIPAL / 2);
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.nav(), PRINCIPAL * 2 - PRINCIPAL / 2);

        vm.prank(holder);
        vm.expectRevert(Pool.RedeemExceedsIdle.selector);
        pool.redeem(PRINCIPAL);
    }

    function test_deficient_blocksAuthorize() public {
        deal(address(token), address(pool), 0);
        pool.sync();
        assertEq(uint8(pool.life()), uint8(Pool.Life.DEFICIENT));
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha, _noMods());
    }

    function _privatePool(uint16 feeBps) internal returns (Pool) {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory deps = new address[](1);
        deps[0] = holder;
        return _withOperator(Pool(factory.createPool(sps, address(token), cs, false, deps, feeBps)));
    }

    /// @dev The Controller registers its operator tag (Anexo R, 2026-10-05): a deal the passport identifies is acted
    ///      through a proven operator, and the pool does not authorize one without it.
    function _withOperator(Pool p) internal returns (Pool) {
        vm.prank(controller);
        p.setOperatorTag(bytes32(uint256(1)));
        return p;
    }

    function _openPool(uint16 feeBps) internal returns (Pool) {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory none = new address[](0);
        return _withOperator(Pool(factory.createPool(sps, address(token), cs, true, none, feeBps)));
    }

    function _fundLp(address lp, Pool p, uint256 amount) internal {
        token.mint(lp, amount);
        vm.startPrank(lp);
        token.approve(address(p), amount);
        p.deposit(amount);
        vm.stopPrank();
    }

    function _activateOn(Pool p, uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32 id, DealTerms memory terms)
    {
        terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }

    function _poolHolderTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
    }

    function _activatePool(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _poolHolderTerms();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }

    /// A pool as Holder cannot vouch for a payment key (§E.3.12.1, RailKeys). Its EIP-1271 only answers for
    /// the digests `authorize` registered, so a key approval fails closed — whoever signs it, the Controller
    /// included. That is the point: a Controller able to approve keys could release the pool's principal to
    /// a colluding Provider with a false one, and a Controller must never be able to redirect principal.
    function test_poolHolder_cannotApproveKeys() public {
        bytes32 id = _activatePool(1, 1, 1);
        PinnedAnchors.Anchor[] memory a = new PinnedAnchors.Anchor[](1);
        a[0] = PinnedAnchors.Anchor({keyHash: keccak256("pinned"), validFrom: 1, validUntil: 2});
        RailKeysHarness rail = new RailKeysHarness(a);
        bytes32 key = keccak256("a key the Controller would like to count");
        IPaymentVerifier.PaymentClaim memory claim = IPaymentVerifier.PaymentClaim({
            dealId: id, fiatCommit: FIAT_COMMIT, notBefore: uint64(escrow.clocks(id).activatedAt), holder: address(pool)
        });
        bytes memory byController = _sign(rail.keyApprovalDigest(id, key), controllerPk);
        (bool ok,,) = rail.keyAllowed(claim, key, byController);
        assertFalse(ok, "the Controller cannot vouch for the pool");
        bytes memory bySponsor = _sign(rail.keyApprovalDigest(id, key), holderPk);
        (ok,,) = rail.keyAllowed(claim, key, bySponsor);
        assertFalse(ok, "nor can the Sponsor");
        assertEq(pool.isValidSignature(rail.keyApprovalDigest(id, key), byController), bytes4(0));
    }

    function test_nav_dropsOnReleaseBeforeReconcile() public {
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        bytes32 id = _activatePool(1, 1, 1);
        assertEq(pool.nav(), PRINCIPAL * 2);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        assertEq(pool.nav(), PRINCIPAL);
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.credits(), 0);
        pool.sync();
        assertEq(pool.locked(), 0);
        assertEq(pool.credits(), 0);
        assertEq(pool.nav(), PRINCIPAL);
    }

    function test_deposit_afterReleaseDoesNotDilute() public {
        Pool p = _openPool(0);
        address lpA = address(0xA0A2);
        address lpB = address(0xB0B2);
        _fundLp(lpA, p, PRINCIPAL * 2);
        (bytes32 id,) = _activateOn(p, 1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);

        _fundLp(lpB, p, PRINCIPAL);
        assertEq(p.sharesOf(lpB), PRINCIPAL * 2);
        assertEq(p.totalShares(), PRINCIPAL * 4);
        assertEq(p.nav(), PRINCIPAL * 2);
        assertEq(p.credits(), 0);
        assertEq(p.locked(), 0);
    }

    function test_redeem_afterReleaseCannotDrainAgainstPhantom() public {
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);

        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        assertEq(token.balanceOf(holder), before + PRINCIPAL / 2);
        assertEq(pool.idle(), PRINCIPAL / 2);
        assertEq(pool.nav(), PRINCIPAL / 2);
    }

    function test_authorize_approvesExactOutstanding() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha, _noMods());
        assertEq(token.allowance(address(pool), address(escrow)), PRINCIPAL);

        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        HolderAuthorization memory ha2 = _holderAuth(_poolHolderTerms(), 2);
        vm.prank(controller);
        pool.authorize(ha2, _noMods());
        assertEq(token.allowance(address(pool), address(escrow)), PRINCIPAL * 2);

        DealTerms memory terms = _poolHolderTerms();
        escrow.activate(
            ha,
            "",
            _providerAuth(terms, 1),
            _signProvider(_providerAuth(terms, 1)),
            _controllerAuth(terms, 1),
            _signController(_controllerAuth(terms, 1))
        );
        pool.sync();
        assertEq(token.allowance(address(pool), address(escrow)), PRINCIPAL);
    }

    function test_reputation_reservesActivationFee() public {
        uint256 actBps = 1_000;
        uint256 actFee = PRINCIPAL * actBps / 10_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), actBps, 0, 0, 0, address(escrow));
        passport.setHuman(address(pool), keccak256("pool"));
        passport.setHuman(provider, keccak256("prov"));

        token.mint(holder, actFee);
        vm.prank(holder);
        pool.deposit(actFee);

        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        pool.authorize(ha, _mods(address(passport), address(rep)));
        assertEq(pool.locked(), PRINCIPAL + actFee);
        assertEq(pool.idle(), 0);
        assertEq(token.allowance(address(pool), address(escrow)), PRINCIPAL + actFee);

        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(rep);
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca), mods);
        assertEq(token.balanceOf(address(0xFEE)), actFee);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        pool.sync();
        assertEq(pool.consumed(), actFee);
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.nav(), PRINCIPAL);
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_reputation_shortIdleReverts() public {
        uint256 actBps = 1_000;
        uint256 actFee = PRINCIPAL * actBps / 10_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), actBps, 0, 0, 0, address(escrow));
        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(_holderAuth(terms, 1), _mods(address(passport), address(rep)));
    }

    function test_reputation_unknownModuleReverts() public {
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), 1, 0, 0, 0, address(escrow));
        vm.prank(controller);
        // `authorize` now runs `Packages.resolve` before reserving anything, so a named module that no signed
        // id refers to is rejected with the kernel's own error instead of `Pool.BadTerms` from `_activationFee`.
        vm.expectRevert(Packages.UnknownPackage.selector);
        pool.authorize(_holderAuth(_poolHolderTerms(), 1), _mods(address(passport), address(rep)));
    }

    /// The other half of the same guarantee, and the state that used to under-reserve the activation fee: a
    /// deal whose signed ids include REPUTATION cannot be authorized with that slot left empty. `resolve`
    /// requires every signed id to be matched, so this fails closed before any value moves.
    function test_reputation_unnamedModuleReverts() public {
        uint256 actBps = 1_000;
        uint256 actFee = PRINCIPAL * actBps / 10_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), actBps, 0, 0, 0, address(escrow));
        passport.setHuman(address(pool), keccak256("pool"));
        passport.setHuman(provider, keccak256("prov"));
        token.mint(holder, actFee);
        vm.prank(holder);
        pool.deposit(actFee);

        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        // mods.reputation deliberately left at zero

        vm.prank(controller);
        vm.expectRevert(Packages.UnknownPackage.selector);
        pool.authorize(_holderAuth(terms, 1), mods);

        assertEq(pool.locked(), 0, "nothing was reserved");
        assertEq(pool.idle(), PRINCIPAL + actFee, "idle untouched");
        assertEq(IERC20(address(token)).allowance(address(pool), address(escrow)), 0, "no allowance granted");
    }

    function test_unlock_returnsActivationFee() public {
        uint256 actBps = 1_000;
        uint256 actFee = PRINCIPAL * actBps / 10_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), actBps, 0, 0, 0, address(escrow));
        token.mint(holder, actFee);
        vm.prank(holder);
        pool.deposit(actFee);
        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        pool.authorize(ha, _mods(address(passport), address(rep)));
        vm.warp(ha.deadline + 1);
        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL + actFee);
        assertEq(pool.locked(), 0);
        assertEq(token.allowance(address(pool), address(escrow)), 0);
    }

    function test_arrangement_defaultsLeaveControllerSkinInGame() public view {
        assertFalse(pool.reimburseContest());
        assertFalse(pool.payControllerOnFullReturn());
    }

    function test_arrangement_settersOnlySponsor() public {
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.setReimburseContest(true);
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.setPayControllerOnFullReturn(true);
        vm.prank(holder);
        pool.setReimburseContest(true);
        vm.prank(holder);
        pool.setPayControllerOnFullReturn(true);
        assertTrue(pool.reimburseContest());
        assertTrue(pool.payControllerOnFullReturn());
    }

    /// Default: contest-open is the Controller's skin. `authorize` does not reserve it.
    function test_reimburseContest_off_doesNotReserve() public {
        uint256 floor_ = 10_000_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), 0, 0, 100, floor_, address(escrow));
        passport.setHuman(address(pool), keccak256("pool"));
        passport.setHuman(provider, keccak256("prov"));
        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        vm.prank(controller);
        pool.authorize(_holderAuth(terms, 1), _mods(address(passport), address(rep)));
        assertEq(pool.locked(), PRINCIPAL);
        assertEq(pool.idle(), 0);
    }

    /// Desk that reimburses contest: reserve at authorize, pay the Controller iff they opened the fight.
    function test_reimburseContest_paysControllerWhenFightOpened() public {
        uint256 floor_ = 10_000_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), 0, 0, 100, floor_, address(escrow));
        passport.setHuman(address(pool), keccak256("pool"));
        passport.setHuman(provider, keccak256("prov"));
        vm.prank(holder);
        pool.setReimburseContest(true);
        token.mint(holder, floor_);
        vm.prank(holder);
        pool.deposit(floor_);

        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        pool.authorize(ha, _mods(address(passport), address(rep)));
        assertEq(pool.locked(), PRINCIPAL + floor_);

        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        bytes32 id = escrow.activate(
            ha, "", pa, _signProvider(pa), ca, _signController(ca), _mods(address(passport), address(rep))
        );
        vm.prank(provider);
        escrow.markFiat(id);
        token.mint(controller, floor_);
        vm.prank(controller);
        token.approve(address(escrow), floor_);
        vm.prank(controller);
        escrow.openDisputed(id);
        assertTrue(escrow.contestPaid(id));
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        pool.reconcile(1);
        // The deal carries no tribunal, so a fight nobody settled is a deadlock: the principal is burned
        // (Anexo R, 2026-09-24). The reimbursement policy is unchanged: the vault still covers the
        // contest the Controller paid from their own wallet.
        assertEq(token.balanceOf(controller), floor_, "pool reimburses the opener");
        assertEq(pool.consumed(), PRINCIPAL + floor_, "the whole principal, plus the reimbursed contest");
    }

    /// Fight never opened: the contest reserve returns to idle, LPs are not charged.
    function test_reimburseContest_unusedReserveReturnsIdle() public {
        uint256 floor_ = 10_000_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), 0, 0, 100, floor_, address(escrow));
        passport.setHuman(address(pool), keccak256("pool"));
        passport.setHuman(provider, keccak256("prov"));
        vm.prank(holder);
        pool.setReimburseContest(true);
        token.mint(holder, floor_);
        vm.prank(holder);
        pool.deposit(floor_);

        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        pool.authorize(ha, _mods(address(passport), address(rep)));
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        bytes32 id = escrow.activate(
            ha, "", pa, _signProvider(pa), ca, _signController(ca), _mods(address(passport), address(rep))
        );
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1);
        assertFalse(escrow.contestPaid(id));
        assertEq(token.balanceOf(controller), 0);
        assertEq(pool.idle(), floor_);
        assertEq(pool.consumed(), PRINCIPAL);
    }

    function test_unlock_returnsContestReserve() public {
        uint256 floor_ = 10_000_000;
        PassportMock passport = new PassportMock();
        Reputation rep = new Reputation(passport, address(0xFEE), 0, 0, 100, floor_, address(escrow));
        vm.prank(holder);
        pool.setReimburseContest(true);
        token.mint(holder, floor_);
        vm.prank(holder);
        pool.deposit(floor_);
        DealTerms memory terms = _poolHolderTerms();
        terms.packageIds = _sorted2(passport.packageId(), rep.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        pool.authorize(ha, _mods(address(passport), address(rep)));
        vm.warp(ha.deadline + 1);
        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL + floor_);
        assertEq(pool.locked(), 0);
    }

    /// Desk that pays the Controller even when the Holder got everything back.
    function test_payControllerOnFullReturn_paysFeeOnCancel() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        vm.prank(holder);
        p.setPayControllerOnFullReturn(true);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        vm.prank(provider);
        escrow.cancelByProvider(id);
        p.reconcile(1);
        assertEq(p.idle(), PRINCIPAL);
        assertEq(p.consumed(), fee);
        assertEq(token.balanceOf(controller), fee);
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

    function _signHolderAsController(ControllerAcceptance memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashControllerAcceptance(a)), holderPk);
    }
}
