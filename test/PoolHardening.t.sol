// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods,
    PackageData,
    MutualCancel
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Escrow} from "../src/Escrow.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {BlockingToken} from "./ContestCreditFirst.t.sol";
import {BaseTest} from "./Base.t.sol";
import {PanelBonds} from "./PanelBonds.sol";

/// @title What the evaluation of 2026-09-28 found in the pools
/// @notice * a deadlock burned the LPs' principal and still paid the Controller its fee;
///         * an LP could redeem at full NAV while a deal it would lose was in a fight, leaving the loss to the
///           ones who stayed — and a newcomer could buy in at that price;
///         * the pool's signature bounded nothing: one Controller could commit all the idle, in any size, in
///           deals with no tribunal;
///         * a payout the escrow could not push to the pool sat in credit with no way to fetch it;
///         * a pool could not sit on a panel deal — it neither reserved the court's availability share nor
///           could sign the panel's appointment;
///         * the factory marked "official" a pool pointed at any escrow.
contract PoolHardeningTest is BaseTest, PanelBonds {
    PoolFactory internal factory;
    Pool internal pool;
    address internal lp = address(0x11);

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory(address(escrow));
        pool = _pool(address(token), 100); // a 1% Controller fee
        _fund(pool, PRINCIPAL * 5);
    }

    // --- the factory ----------------------------------------------------------------------------------

    function test_factory_pinsTheEscrow() public view {
        assertEq(factory.escrow(), address(escrow));
        assertEq(pool.escrow(), address(escrow), "an official pool can only point at the escrow its factory names");
        assertTrue(factory.isOfficial(address(pool)));
    }

    /// A clone of the implementation made outside the factory has the official codehash and any escrow it likes.
    function test_factory_aCloneItDidNotMake_isNotOfficial() public {
        Pool rogue = Pool(Clones.clone(factory.implementation()));
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        rogue.initialize(sps, address(token), address(0xE5C), none, true, none, 0);
        assertEq(address(rogue).codehash, factory.officialCodehash(), "the same bytecode");
        assertFalse(factory.isOfficial(address(rogue)), "but not the factory's, so not official");
    }

    // --- the deadlock -----------------------------------------------------------------------------------

    function test_aBurnedPrincipal_paysTheControllerNothing() public {
        bytes32 id = _activate(pool, 1);
        _markFiat(id);
        vm.prank(controller);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        pool.reconcile(1);
        assertEq(pool.controllerCredit(controller), 0, "nobody is paid for letting the LPs' principal burn");
        assertEq(pool.consumed(), PRINCIPAL, "the principal is gone, the fee is not");
    }

    // --- the fight ------------------------------------------------------------------------------------

    function test_aFightInFlight_freezesDepositsAndRedemptions() public {
        bytes32 id = _activate(pool, 1);
        _markFiat(id);
        vm.prank(controller);
        escrow.openDisputed(id);
        token.mint(lp, PRINCIPAL);
        vm.startPrank(lp);
        token.approve(address(pool), PRINCIPAL);
        vm.expectRevert(Pool.FightInFlight.selector);
        pool.deposit(PRINCIPAL);
        vm.expectRevert(Pool.FightInFlight.selector);
        pool.redeem(1);
        vm.stopPrank();
        // Settled: the books move again.
        _mutualCancelAsController(id);
        pool.reconcile(1);
        vm.prank(lp);
        pool.redeem(1);
    }

    // --- the limits ------------------------------------------------------------------------------------

    function test_limits_capThePrincipalOfOneDeal() public {
        vm.prank(holder);
        pool.setLimits(PRINCIPAL - 1, 0, false);
        HolderAuthorization memory ha = _holderAuth(_terms(pool), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.OverLimit.selector);
        pool.authorize(ha, _noMods());
    }

    function test_limits_capWhatOneControllerHasOpen() public {
        vm.prank(holder);
        pool.setLimits(0, PRINCIPAL, false);
        HolderAuthorization memory first = _holderAuth(_terms(pool), 1);
        vm.prank(controller);
        pool.authorize(first, _noMods());
        HolderAuthorization memory second = _holderAuth(_terms(pool), 2);
        vm.prank(controller);
        vm.expectRevert(Pool.OverLimit.selector);
        pool.authorize(second, _noMods());
        // The first one dies unused: the Controller's room comes back.
        vm.warp(first.deadline + 1);
        pool.unlock(1);
        HolderAuthorization memory third = _holderAuth(_terms(pool), 3);
        third.deadline = vm.getBlockTimestamp() + 1 days; // via_ir caches block.timestamp across a warp
        vm.prank(controller);
        pool.authorize(third, _noMods());
    }

    function test_limits_canRequireATribunal() public {
        vm.prank(holder);
        pool.setLimits(0, 0, true);
        HolderAuthorization memory ha = _holderAuth(_terms(pool), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.CourtRequired.selector);
        pool.authorize(ha, _noMods());
    }

    function test_limits_areTheSponsors() public {
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.setLimits(1, 1, true);
    }

    // --- credit ---------------------------------------------------------------------------------------

    function test_aPayoutTheEscrowCouldNotPush_canBeFetched() public {
        BlockingToken blocking = new BlockingToken();
        Pool p = _pool(address(blocking), 0);
        blocking.mint(lp, PRINCIPAL);
        vm.startPrank(lp);
        blocking.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        DealTerms memory t = _terms(p);
        t.token = address(blocking);
        bytes32 id = _activateTerms(p, t, 1);
        blocking.block_(address(p));
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(escrow.creditOf(address(blocking), address(p)), PRINCIPAL, "the refund waits in the escrow");
        blocking.unblock(address(p));
        p.pullEscrowCredit();
        assertEq(escrow.creditOf(address(blocking), address(p)), 0);
        assertEq(blocking.balanceOf(address(p)), PRINCIPAL, "and now sits in the pool");
        p.reconcile(1);
        vm.prank(lp);
        p.redeem(PRINCIPAL);
        assertEq(blocking.balanceOf(lp), PRINCIPAL);
    }

    // --- a panel deal ----------------------------------------------------------------------------------

    /// A pool sits on a panel deal like any peer: with its own bond, from its own capital (Anexo R, 2026-10-05).
    function test_aPoolCanSitOnAPanelDeal() public {
        _deployBonds(address(escrow));
        _bondSide(token, address(pool), PRINCIPAL);
        _bondSide(token, provider, PRINCIPAL);
        ArbiterRegistry registry = new ArbiterRegistry(
            address(escrow),
            address(token),
            ArbiterRegistry.Policy(1 days, 1 days, 7 days, 1_000, 5_000, 20, 3_000),
            address(0),
            address(bondVault),
            address(0),
            address(0),
            bytes32(0),
            address(0)
        );
        uint256[3] memory pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
        address[3] memory panel;
        for (uint256 i; i < 3; i++) {
            panel[i] = vm.addr(pks[i]);
            token.mint(panel[i], PRINCIPAL);
            vm.startPrank(panel[i]);
            token.approve(address(registry), type(uint256).max);
            registry.deposit(PRINCIPAL);
            registry.setEncryptionKey(keccak256(abi.encode("x25519", i)));
            vm.stopPrank();
        }
        DealTerms memory t = _terms(pool);
        t.arbitrationDuration = 3 days;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.packageId();
        t.packageIds = _withBondIds(ids);
        PackageMods memory mods;
        mods.court = address(registry);
        mods = _withBondMods(mods);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca = _controllerAuth(t, 1);
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 1);

        uint256 idleBefore = pool.idle();
        vm.prank(controller);
        pool.authorize(ha, mods);
        uint256 share = PRINCIPAL * 60 / 10_000;
        assertEq(idleBefore - pool.idle(), PRINCIPAL + PRINCIPAL / 100 + share, "principal, desk fee, availability");

        bytes32 appointment = registry.appointmentDigest(id, panel);
        vm.prank(controller);
        pool.approveCourtDigest(1, appointment);
        bytes[3] memory accepts;
        for (uint256 i; i < 3; i++) {
            accepts[i] = _sign(appointment, pks[i]);
        }
        PackageData memory data;
        data.court = abi.encode(panel, bytes(""), _sign(appointment, providerPk), accepts);
        bytes32 got = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca), mods, data);
        assertEq(got, id);
        assertEq(token.balanceOf(address(registry)), 3 * PRINCIPAL + share, "the pool paid the availability");
    }

    /// The court owes the pool, as Holder, the availability no arbiter earned (a dispute nobody escalated, an
    /// abstention) and the slash of an arbiter when the pool lost without being heard. Fetched into idle: it is
    /// the LPs' money coming back.
    function test_aCourtCredit_isFetchedIntoIdle() public {
        CreditingCourt court = new CreditingCourt(address(token));
        token.mint(address(court), 777);
        court.owe(address(pool), 777);
        uint256 idleBefore = pool.idle();
        vm.prank(controller);
        pool.pullCourtCredit(address(court));
        assertEq(pool.idle(), idleBefore + 777);
        vm.prank(lp);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.pullCourtCredit(address(court));
    }

    // --- helpers ----------------------------------------------------------------------------------------

    function _pool(address tok, uint16 feeBps) internal returns (Pool) {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, tok, cs, true, none, feeBps));
        vm.prank(controller);
        p.setOperatorTag(bytes32(uint256(1))); // Anexo R, 2026-10-05: the Controller acts as a registered operator
        return p;
    }

    function _fund(Pool p, uint256 amount) internal {
        token.mint(lp, amount);
        vm.startPrank(lp);
        token.approve(address(p), amount);
        p.deposit(amount);
        vm.stopPrank();
    }

    function _terms(Pool p) internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(p);
        t.controller = controller;
    }

    function _activate(Pool p, uint256 nonce) internal returns (bytes32) {
        return _activateTerms(p, _terms(p), nonce);
    }

    function _activateTerms(Pool p, DealTerms memory t, uint256 nonce) internal returns (bytes32) {
        HolderAuthorization memory ha = _holderAuth(t, nonce);
        ProviderAgreement memory pa = _providerAuth(t, nonce);
        ControllerAcceptance memory ca = _controllerAuth(t, nonce);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }

    function _mutualCancelAsController(bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualCancel memory p = MutualCancel({dealId: id, nonce: 91, deadline: deadline});
        MutualCancel memory c = MutualCancel({dealId: id, nonce: 92, deadline: deadline});
        escrow.mutualCancel(
            p,
            _sign(_typed(Consent.hashMutualCancel(p)), providerPk),
            c,
            _sign(_typed(Consent.hashMutualCancel(c)), controllerPk)
        );
    }
}

/// @dev A court that owes credits and pays them on `withdrawCredit`, as ArbiterRegistry does.
contract CreditingCourt {
    address internal immutable token;
    mapping(address => uint256) public creditOf;

    constructor(address token_) {
        token = token_;
    }

    function owe(address who, uint256 amount) external {
        creditOf[who] += amount;
    }

    function withdrawCredit() external {
        uint256 amount = creditOf[msg.sender];
        creditOf[msg.sender] = 0;
        IERC20(token).transfer(msg.sender, amount);
    }
}
