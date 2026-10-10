// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Escrow} from "../src/Escrow.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {BaseTest} from "./Base.t.sol";

/// @title The kernel charges its own fee, to the DAO
/// @notice PROTOCOLO.md Anexo R, 2026-10-02. Every deal pays 0.3% of its principal at activation, from the
///         Holder on top of the principal, and 0.3% at a terminal that pays the Provider and is not a
///         stalemate. Both are accrued in the kernel and swept to an immutable recipient.
contract KernelFeeTest is BaseTest {
    address internal constant DAO = address(0xDA0);
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint16 internal constant BPS = 30;
    uint256 internal constant FEE = PRINCIPAL * BPS / 10_000;

    function setUp() public override {
        super.setUp();
        escrow = new Escrow(DAO, BPS, BPS);
        token.mint(holder, FEE);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
    }

    // --- deployment ----------------------------------------------------------------------------------

    function test_constructor_rejectsAShareAboveTheCeiling() public {
        vm.expectRevert(Escrow.BadKernelFee.selector);
        new Escrow(DAO, 101, BPS);
        vm.expectRevert(Escrow.BadKernelFee.selector);
        new Escrow(DAO, BPS, 101);
    }

    function test_constructor_rejectsAShareWithoutARecipient() public {
        vm.expectRevert(Escrow.BadKernelFee.selector);
        new Escrow(address(0), BPS, 0);
        vm.expectRevert(Escrow.BadKernelFee.selector);
        new Escrow(address(0), 0, BPS);
    }

    function test_constructor_feeFreeKernelIsValid() public {
        Escrow free = new Escrow(address(0), 0, 0);
        assertEq(free.feeRecipient(), address(0));
        assertEq(free.activationBps(), 0);
        assertEq(free.completionBps(), 0);
    }

    function test_policyIsReadable() public view {
        assertEq(escrow.feeRecipient(), DAO);
        assertEq(escrow.activationBps(), BPS);
        assertEq(escrow.completionBps(), BPS);
    }

    // --- activation ----------------------------------------------------------------------------------

    function test_activation_pullsTheShareOnTopOfThePrincipal() public {
        (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps) = _signed();
        ControllerAcceptance memory ca;
        _expectFee(Packages.FeeKind.Activation);
        escrow.activate(ha, hs, pa, ps, ca, "");
        assertEq(token.balanceOf(holder), 0, "principal + share");
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL + FEE);
        assertEq(escrow.feesOwed(address(token)), FEE);
        assertEq(token.balanceOf(DAO), 0, "accrued, not pushed");
    }

    function test_activation_failsWithoutAllowanceForTheShare() public {
        vm.prank(holder);
        token.approve(address(escrow), PRINCIPAL);
        (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps) = _signed();
        ControllerAcceptance memory ca;
        vm.expectRevert();
        escrow.activate(ha, hs, pa, ps, ca, "");
    }

    /// A signature over a fee-free kernel is not a signature over this one: the domain names the contract,
    /// and the contract is its fee.
    function test_activation_signatureForAnotherKernelDoesNotActivateHere() public {
        Escrow free = new Escrow(address(0), 0, 0);
        DealTerms memory terms = _p2pTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _sign(
            MessageHashUtils.toTypedDataHash(free.domainSeparator(), Consent.hashHolderAuthorization(ha)), holderPk
        );
        bytes memory ps = _sign(
            MessageHashUtils.toTypedDataHash(free.domainSeparator(), Consent.hashProviderAgreement(pa)), providerPk
        );
        vm.expectRevert(Escrow.InvalidHolderSignature.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
    }

    function test_activation_dustPrincipalPaysNothing() public {
        DealTerms memory terms = _p2pTerms();
        terms.principal = 333; // 333 * 30 / 10_000 rounds to zero
        _activateP2PWith(terms, 1, 1);
        assertEq(escrow.feesOwed(address(token)), 0);
    }

    // --- terminals -------------------------------------------------------------------------------------

    function test_release_takesTheCompletionShareFromThePot() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        _expectFee(Packages.FeeKind.Completion);
        vm.prank(holder);
        escrow.release(id);
        assertEq(token.balanceOf(provider), PRINCIPAL - FEE);
        assertEq(escrow.feesOwed(address(token)), 2 * FEE);
        (, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(h, 0);
        assertEq(p, PRINCIPAL - FEE);
    }

    /// The activation share is the price of the deal having existed; a refund has no completion.
    function test_cancel_keepsTheActivationShareAndChargesNoCompletion() public {
        bytes32 id = _activateP2P(1, 1);
        vm.warp(block.timestamp + 3600);
        escrow.timeoutFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL, "the principal comes back in full");
        assertEq(escrow.feesOwed(address(token)), FEE, "the activation share does not");
    }

    /// Invoiced on the whole principal before the split, so both sides bear it in proportion.
    function test_split_chargesTheCompletionShareBeforeSplitting() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        _mutualSplit(id, 5_000, 2, 3);
        uint256 pot = PRINCIPAL - FEE;
        assertEq(token.balanceOf(provider), pot / 2);
        assertEq(token.balanceOf(holder), pot - pot / 2);
        assertEq(escrow.feesOwed(address(token)), 2 * FEE);
    }

    /// A deadlock burns the principal and pays the DAO nothing on top: nobody may gain from a failed deal.
    function test_deadlock_burnsTheWholePrincipalAndChargesNoCompletion() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(BURN), PRINCIPAL);
        assertEq(escrow.feesOwed(address(token)), FEE);
    }

    function test_claim_chargesTheCompletionShare() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        vm.warp(block.timestamp + 1800);
        escrow.claim(id);
        assertEq(token.balanceOf(provider), PRINCIPAL - FEE);
        assertEq(escrow.feesOwed(address(token)), 2 * FEE);
    }

    // --- sweep -----------------------------------------------------------------------------------------

    function test_sweep_anyoneDeliversToTheRecipient() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Escrow.FeesSwept(address(token), DAO, 2 * FEE);
        vm.prank(address(0xBEEF));
        escrow.sweepFees(address(token));
        assertEq(token.balanceOf(DAO), 2 * FEE);
        assertEq(escrow.feesOwed(address(token)), 0);
        assertEq(token.balanceOf(address(escrow)), 0, "nothing left behind");
    }

    function test_sweep_nothingOwedIsANoOp() public {
        escrow.sweepFees(address(token));
        assertEq(token.balanceOf(DAO), 0);
    }

    /// The reason the kernel accrues instead of pushing: a recipient the token refuses must stop the sweep
    /// alone, never a deal.
    function test_sweep_refusedRecipientBlocksNoDeal() public {
        bytes32 first = _activateP2P(1, 1);
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (DAO, FEE)), "blocked");
        vm.expectRevert();
        escrow.sweepFees(address(token));
        assertEq(escrow.feesOwed(address(token)), FEE, "still owed");

        // A second deal activates and closes while the recipient is refused.
        _markFiat(first);
        vm.prank(holder);
        escrow.release(first);
        token.mint(holder, PRINCIPAL + FEE);
        bytes32 second = _activateP2P(2, 2);
        _markFiat(second);
        vm.prank(holder);
        escrow.release(second);
        assertEq(uint8(escrow.status(second)), uint8(Status.RELEASED));
        assertEq(escrow.feesOwed(address(token)), 4 * FEE);

        vm.clearMockedCalls();
        escrow.sweepFees(address(token));
        assertEq(token.balanceOf(DAO), 4 * FEE);
    }

    // --- pools -----------------------------------------------------------------------------------------

    /// A pool is the Holder, so it reserves the kernel's activation share with the principal: without it the
    /// escrow allowance would be short and the deal could not activate.
    function test_pool_reservesTheKernelShare() public {
        Pool p = _pool();
        _deposit(p, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_poolTerms(p), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        p.authorize(ha, _noMods());

        _deposit(p, FEE);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        assertEq(p.locked(), PRINCIPAL + FEE);
        assertEq(p.idle(), 0);
    }

    function test_pool_dealActivatesAndTheShareIsConsumed() public {
        Pool p = _pool();
        _deposit(p, PRINCIPAL + FEE);
        DealTerms memory terms = _poolTerms(p);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha, _noMods());
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        assertEq(token.balanceOf(address(p)), 0);
        assertEq(p.nav(), PRINCIPAL, "the share left the pool");

        _markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1);
        assertEq(p.locked(), 0);
        assertEq(p.idle(), 0);
        assertEq(p.consumed(), PRINCIPAL + FEE);
        assertEq(uint8(p.life()), uint8(Pool.Life.ACTIVE));
    }

    // --- helpers ---------------------------------------------------------------------------------------

    /// A P2P deal's two signatures, made before any `expect*` so the cheatcode applies to `activate` itself.
    function _signed()
        internal
        view
        returns (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps)
    {
        ha = _holderAuth(_p2pTerms(), 1);
        pa = _providerAuth(_p2pTerms(), 1);
        hs = _signHolder(ha);
        ps = _signProvider(pa);
    }

    /// The deal id is not known before activation, so only the recipient topic and the data are checked.
    function _expectFee(Packages.FeeKind kind) internal {
        vm.expectEmit(false, true, false, true, address(escrow));
        emit Packages.FeeCharged(bytes32(0), kind, DAO, FEE);
    }

    function _pool() internal returns (Pool) {
        PoolFactory factory = new PoolFactory(address(escrow));
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory deps = new address[](1);
        deps[0] = holder;
        return Pool(factory.createPool(sps, address(token), cs, false, deps, 0));
    }

    function _deposit(Pool p, uint256 amount) internal {
        token.mint(holder, amount);
        vm.startPrank(holder);
        token.approve(address(p), amount);
        p.deposit(amount);
        vm.stopPrank();
    }

    function _poolTerms(Pool p) internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(p);
        t.controller = controller;
    }
}
