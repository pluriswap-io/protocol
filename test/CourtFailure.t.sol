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
import {Escrow} from "../src/Escrow.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {BaseTest} from "./Base.t.sol";

/// @title What happens when the tribunal the parties chose cannot do its job
/// @notice PROTOCOLO.md Anexo R, 2026-09-29: an unopenable court follows the no-tribunal branch, there is no
///         split inside ARBITRATION_ACTIVE either, and the court's own timeout is the no-tribunal branch.
/// @dev Abandonment is imputed only to whoever COULD escalate and did not. A court that answers "not
///      available" (or does not answer at all) leaves the Controller nothing to escalate to, so the dispute
///      clock is a deadlock, exactly as in a deal that never signed ARBITRATION — never a free win for a
///      Provider who may have lied. And once a court is open, the fight ends in a ruling, an all-or-nothing
///      agreement, or the same deadlock: no half-and-half extracted with the clock as a threat.
contract CourtFailureTest is BaseTest {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    AvailabilityCourt internal court;

    function setUp() public override {
        super.setUp();
        court = new AvailabilityCourt(address(escrow), address(token));
    }

    // --- D1: a court that cannot be opened ------------------------------------------------------------------

    /// The guard: with a court that can be used, walking away from the fight still loses it.
    function test_availableCourt_disputeTimeoutIsStillAbandonment() public {
        court.setAvailable(true);
        bytes32 id = _activateWithCourt(1, 2);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.ABANDONED));
    }

    function test_unavailableCourt_disputeTimeoutFollowsTheNoTribunalBranch() public {
        court.setAvailable(false);
        bytes32 id = _activateWithCourt(3, 4);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE), "nobody could escalate, so nobody abandoned");
        assertEq(holderAmt, 0, "the deadlock pays nobody");
        assertEq(providerAmt, 0, "in particular not a Provider who may have lied");
        assertEq(token.balanceOf(BURN), PRINCIPAL);
    }

    // --- D2: inside ARBITRATION_ACTIVE ----------------------------------------------------------------------

    function test_noSplitInsideArbitration_openedFromFiatSent() public {
        court.setAvailable(true);
        bytes32 id = _activateWithCourt(5, 6);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        vm.expectRevert(Escrow.SplitAfterDispute.selector);
        this.splitExternally(id, 5000, 7, 8);
    }

    function test_noSplitInsideArbitration_openedFromDisputed() public {
        court.setAvailable(true);
        bytes32 id = _activateWithCourt(9, 10);
        _markFiat(id);
        _openDisputed(id);
        vm.prank(holder);
        escrow.openCourt(id);
        vm.expectRevert(Escrow.SplitAfterDispute.selector);
        this.splitExternally(id, 5000, 11, 12);
    }

    function test_arbitrationTimeout_followsTheNoTribunalBranch() public {
        court.setAvailable(true);
        bytes32 id = _activateWithCourt(13, 14);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        vm.warp(block.timestamp + 1 days);
        escrow.forceArbitrationTimeout(id);
        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE));
        assertEq(holderAmt, 0, "stretching the court to its clock no longer buys half");
        assertEq(providerAmt, 0);
        assertEq(token.balanceOf(BURN), PRINCIPAL);
    }

    /// The all-or-nothing agreements stay open inside the fight.
    function test_insideArbitration_mutualCancelStillWorks() public {
        court.setAvailable(true);
        bytes32 id = _activateWithCourt(15, 16);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        _mutualCancel(id, 17, 18);
        (Status st, uint256 holderAmt,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CANCELLED));
        assertEq(holderAmt, PRINCIPAL);
    }

    function splitExternally(bytes32 id, uint16 bps, uint256 pn, uint256 cn) external {
        _mutualSplit(id, bps, pn, cn);
    }

    function _activateWithCourt(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        DealTerms memory terms = _p2pTerms();
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = court.packageId();
        PackageMods memory mods;
        mods.court = address(court);
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }
}

/// @dev A free court that says whether it can take a deal. The kernel asks at the dispute timeout.
contract AvailabilityCourt is ArbitrationMock {
    bool internal _available;

    constructor(address escrow_, address token_)
        ArbitrationMock(address(0x71B), token_, 0, 1 days, escrow_, 0, address(0), 0)
    {}

    function setAvailable(bool on) external {
        _available = on;
    }

    function available(bytes32) external view override returns (bool) {
        return _available;
    }
}
