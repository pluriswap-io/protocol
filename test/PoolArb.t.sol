// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {EthCourtMock} from "../mocks/EthCourtMock.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {BaseTest} from "./Base.t.sol";

contract PoolArbTest is BaseTest {
    uint256 internal constant COURT_ETH = 0.01 ether;
    uint16 internal constant FEE_BPS = 100;
    EthCourtMock internal court;
    PoolFactory internal factory;
    Pool internal pool;
    uint256 internal fee;

    function setUp() public override {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        uint64 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 1);
        court = new EthCourtMock(COURT_ETH, predicted, 0, address(0xFEE));
        escrow = new Escrow(address(0), 0, 0);
        assertEq(address(escrow), predicted);

        factory = new PoolFactory(address(escrow));
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory deps = new address[](1);
        deps[0] = holder;
        pool = Pool(factory.createPool(sps, address(token), cs, false, deps, FEE_BPS));
        fee = PRINCIPAL * FEE_BPS / 10_000;

        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(PRINCIPAL + fee);
        vm.stopPrank();
        vm.deal(controller, 1 ether);
    }

    function test_arb_providerWin_paysFeeAndReadsSettlementOf() public {
        bytes32 id = _activateArb(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.openCourt{value: COURT_ETH}(id);
        court.giveRuling(id, 2);
        escrow.readRuling(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(holderAmt, 0);
        assertEq(providerAmt, PRINCIPAL);

        pool.reconcile(1);
        assertEq(pool.consumed(), PRINCIPAL + fee);
        assertEq(pool.idle(), 0);
        assertEq(pool.nav(), 0);
        assertEq(token.balanceOf(controller), fee);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_arb_holderWin_returnsFee() public {
        bytes32 id = _activateArb(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.openCourt{value: COURT_ETH}(id);
        court.giveRuling(id, 1);
        escrow.readRuling(id);

        (Status st, uint256 holderAmt,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(holderAmt, PRINCIPAL);

        pool.reconcile(1);
        assertEq(pool.consumed(), 0);
        assertEq(pool.idle(), PRINCIPAL + fee);
        assertEq(pool.nav(), PRINCIPAL + fee);
        assertEq(token.balanceOf(controller), 0);
    }

    function _activateArb(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _p2pTerms();
        terms.holder = address(pool);
        terms.controller = controller;
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = court.packageId();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        PackageMods memory mods;
        mods.court = address(court);
        vm.prank(controller);
        // `authorize` runs the same `Packages.resolve` the kernel will, so it needs the same slots. Passing
        // zero mods here used to be accepted and silently under-described the deal.
        pool.authorize(ha, mods);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca), mods);
    }
}
