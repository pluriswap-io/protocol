// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Settlement} from "../src/libraries/Settlement.sol";
import {Terms} from "../src/libraries/Terms.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {BpsReputation} from "./ProportionalFees.t.sol";
import {BlockingToken} from "./ContestCreditFirst.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

/// @title What an indexer needs to follow the money
/// @notice Evaluation of 2026-09-28: there were no fee events, no event for a payout that could not be pushed and
///         waited in credit, and none for its withdrawal — an indexer had to deduce fees as `principal - hAmt -
///         pAmt`, which in a deadlock is the burn. Every fee the kernel charges is announced with its kind, every
///         credit and every withdrawal too. The clocks are bounded so no duration can overflow a timeout into
///         impossibility, and `postPending` is on the read surface packages and pools import.
contract KernelEventsTest is BaseTest {
    uint256 internal constant BPS = 30;
    address internal constant FEE_TO = address(0xFEE);

    PassportMock internal passport;
    BpsReputation internal reputation;

    function setUp() public override {
        super.setUp();
        passport = new PassportMock();
        reputation = new BpsReputation(passport, FEE_TO, BPS, BPS, address(escrow));
        passport.setHuman(holder, keccak256("h"));
        passport.setHuman(provider, keccak256("p"));
        token.mint(holder, PRINCIPAL);
    }

    function test_activationFee_isAnnounced() public {
        DealTerms memory terms = _repTerms();
        bytes32 id = _expectedId(terms, 1, 2);
        PackageMods memory mods = _mods(address(passport), address(reputation));
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 2);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Packages.FeeCharged(id, Packages.FeeKind.Activation, FEE_TO, PRINCIPAL * BPS / 10_000);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    function test_completionFee_isAnnounced() public {
        bytes32 id = _activate(_repTerms(), 3, 4);
        _markFiat(id);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Packages.FeeCharged(id, Packages.FeeKind.Completion, FEE_TO, PRINCIPAL * BPS / 10_000);
        vm.prank(holder);
        escrow.release(id);
    }

    function test_contestFee_isAnnounced() public {
        ArbitrationMock court =
            new ArbitrationMock(address(0x71B), address(token), 0, 1 days, address(escrow), 500, FEE_TO, 0);
        DealTerms memory terms = _p2pTerms();
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = court.packageId();
        PackageMods memory mods;
        mods.court = address(court);
        bytes32 id = _activateWith(terms, mods, 5, 6);
        _markFiat(id);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Packages.FeeCharged(id, Packages.FeeKind.Contest, FEE_TO, 500);
        vm.prank(holder);
        escrow.openDisputed(id);
    }

    function test_aRefusedPush_isCreditedAndItsWithdrawalAnnounced() public {
        BlockingToken blocking = new BlockingToken();
        token = blocking;
        blocking.mint(holder, PRINCIPAL);
        vm.prank(holder);
        blocking.approve(address(escrow), type(uint256).max);
        DealTerms memory terms = _p2pTerms();
        terms.token = address(blocking);
        bytes32 id = _activateP2PWith(terms, 7, 8);
        _markFiat(id);
        blocking.block_(provider);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Settlement.Credited(address(blocking), provider, PRINCIPAL);
        vm.prank(holder);
        escrow.release(id);
        blocking.unblock(provider);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Settlement.Withdrawn(address(blocking), provider, PRINCIPAL);
        vm.prank(provider);
        escrow.withdraw(address(blocking));
    }

    function test_aDurationPastUint64_cannotBeSigned() public {
        DealTerms memory terms = _p2pTerms();
        terms.disputeDuration = uint256(type(uint64).max) + 1;
        vm.expectRevert(Terms.DurationTooLong.selector);
        this.hashExternally(terms);
    }

    function test_postPending_isOnTheReadSurface() public {
        bytes32 id = _activateP2P(9, 10);
        assertEq(IEscrow(address(escrow)).postPending(id), 0);
    }

    function hashExternally(DealTerms memory terms) external pure returns (bytes32) {
        return Terms.hashTerms(terms);
    }

    function _repTerms() internal view returns (DealTerms memory terms) {
        terms = _p2pTerms();
        (bytes32 a, bytes32 b) = (passport.packageId(), reputation.packageId());
        terms.packageIds = new bytes32[](2);
        (terms.packageIds[0], terms.packageIds[1]) = a < b ? (a, b) : (b, a);
    }

    function _expectedId(DealTerms memory terms, uint256 hNonce, uint256 pNonce) internal view returns (bytes32) {
        return Consent.dealId(escrow.domainSeparator(), terms, hNonce, pNonce, 0);
    }

    function _activate(DealTerms memory terms, uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        PackageMods memory mods = _mods(address(passport), address(reputation));
        return _activateWith(terms, mods, hNonce, pNonce);
    }

    function _activateWith(DealTerms memory terms, PackageMods memory mods, uint256 hNonce, uint256 pNonce)
        internal
        returns (bytes32)
    {
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }
}
