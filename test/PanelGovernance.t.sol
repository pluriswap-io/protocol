// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageData
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {Governed} from "../src/packages/Governed.sol";
import {ArbiterRegistryTest} from "./ArbiterRegistry.t.sol";

/// @notice The DAO moves the panel's terms and prices for the deals not yet bound, and nothing else (Anexo R,
///         2026-10-06): inside fixed bounds, after a delay longer than the longest exit, enacted by anyone. The
///         `packageId` hashes the policy in force, so a deal signed under the old one does not activate; a live case
///         keeps the terms it was bound under, and the kernel keeps the prices it charged. Inherits the whole panel
///         suite, so every behaviour of the panel is checked again under a governor.
contract PanelGovernanceTest is ArbiterRegistryTest {
    address internal constant DAO = address(0xDA0);

    function _governor() internal pure override returns (address) {
        return DAO;
    }

    /// Longer windows, a bigger lock, the whole lock for an abstention, double the availability, half the share.
    function _next() internal pure returns (ArbiterRegistry.Policy memory) {
        return ArbiterRegistry.Policy(2 days, 2 days, 14 days, 2_000, 10_000, 40, 1_500);
    }

    function _current() internal pure returns (ArbiterRegistry.Policy memory) {
        return ArbiterRegistry.Policy(
            COMMIT, REVEAL, EXIT_DELAY, uint16(LOCK_BPS), uint16(ABSTAIN_BPS), uint16(AVAIL_BPS), uint16(SHARE_BPS)
        );
    }

    function _propose(ArbiterRegistry.Policy memory p) internal {
        vm.prank(DAO);
        registry.proposePolicy(p);
    }

    function _enactNext() internal {
        _propose(_next());
        vm.warp(registry.pendingAt());
        registry.enactPolicy();
    }

    function _sameTerms(ArbiterRegistry.Policy memory a, ArbiterRegistry.Policy memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    // --- who and when --------------------------------------------------------------------------------

    function test_gov_onlyTheGovernorProposesAndCancels() public {
        vm.expectRevert(Governed.NotGovernor.selector);
        registry.proposePolicy(_next());
        _propose(_next());
        vm.expectRevert(Governed.NotGovernor.selector);
        registry.cancelPolicy();
    }

    function test_gov_aFrozenPanelHasNoGovernor() public {
        ArbiterRegistry frozen = new ArbiterRegistry(
            address(escrow),
            address(token),
            _current(),
            address(0),
            address(vault),
            address(0),
            address(0),
            bytes32(0),
            address(0)
        );
        vm.prank(address(0));
        vm.expectRevert(Governed.NotGovernor.selector);
        frozen.proposePolicy(_next());
        assertTrue(frozen.packageId() != registry.packageId(), "the governor is part of the package");
    }

    function test_gov_enactWaitsTheDelay_thenAnyoneEnacts() public {
        _propose(_next());
        uint64 at = registry.pendingAt();
        assertEq(at, vm.getBlockTimestamp() + registry.GOVERNANCE_DELAY());
        assertTrue(_sameTerms(registry.pendingPolicy(), _next()));
        vm.warp(at - 1);
        vm.expectRevert(Governed.PolicyNotDue.selector);
        registry.enactPolicy();
        vm.warp(at);
        vm.prank(address(0xBEEF)); // no keeper: anyone
        registry.enactPolicy();
        assertTrue(_sameTerms(registry.policy(), _next()));
        assertEq(registry.commitWindow(), 2 days);
        assertEq(registry.lockBps(), 2_000);
        assertEq(registry.activationBps(), 120, "three arbiters at the new availability");
        assertEq(registry.bondShareBps(), 1_500);
        assertEq(registry.pendingAt(), 0);
        vm.expectRevert(Governed.NothingPending.selector);
        registry.enactPolicy();
    }

    function test_gov_aNewProposalRestartsTheDelay() public {
        uint256 t0 = vm.getBlockTimestamp();
        _propose(_next());
        vm.warp(t0 + 20 days);
        ArbiterRegistry.Policy memory other = ArbiterRegistry.Policy(1 days, 1 days, 7 days, 500, 2_500, 5, 1_000);
        _propose(other);
        assertEq(registry.pendingAt(), t0 + 50 days);
        vm.warp(t0 + 40 days); // the first proposal's time: gone with it
        vm.expectRevert(Governed.PolicyNotDue.selector);
        registry.enactPolicy();
        vm.warp(t0 + 50 days);
        registry.enactPolicy();
        assertTrue(_sameTerms(registry.policy(), other));
    }

    function test_gov_cancelLeavesNothingToEnact() public {
        _propose(_next());
        vm.prank(DAO);
        registry.cancelPolicy();
        vm.warp(vm.getBlockTimestamp() + registry.GOVERNANCE_DELAY());
        vm.expectRevert(Governed.NothingPending.selector);
        registry.enactPolicy();
        assertTrue(_sameTerms(registry.policy(), _current()));
        vm.prank(DAO);
        vm.expectRevert(Governed.NothingPending.selector);
        registry.cancelPolicy();
    }

    /// An arbiter who disagrees with a proposal asks to leave the day it lands, under the longest exit the
    /// bounds allow, and is out before the new terms apply.
    function test_gov_theDelayOutlastsTheLongestExit() public {
        assertGt(registry.GOVERNANCE_DELAY(), registry.MAX_EXIT_DELAY());
        ArbiterRegistry.Policy memory longest = _current();
        longest.exitDelay = registry.MAX_EXIT_DELAY();
        _propose(longest);
        vm.warp(registry.pendingAt());
        registry.enactPolicy();
        _propose(_next());
        vm.prank(arbs[0]);
        registry.requestExit(BOND);
        (,,, uint64 exitAt) = registry.arbiterOf(arbs[0]);
        assertLt(exitAt, registry.pendingAt(), "out before the terms change");
        vm.warp(exitAt);
        vm.prank(arbs[0]);
        registry.exit();
    }

    // --- the bounds ----------------------------------------------------------------------------------

    function test_gov_everyBoundHolds() public {
        ArbiterRegistry.Policy[14] memory bad;
        for (uint256 i; i < bad.length; i++) {
            bad[i] = _current();
        }
        bad[0].commitWindow = 1 days - 1;
        bad[1].commitWindow = 7 days + 1;
        bad[2].revealWindow = 12 hours - 1;
        bad[3].revealWindow = 3 days + 1;
        bad[4].exitDelay = 7 days - 1;
        bad[5].exitDelay = 21 days + 1;
        bad[6].lockBps = 499;
        bad[7].lockBps = 2_501;
        bad[8].abstainSlashBps = 2_499;
        bad[9].abstainSlashBps = 10_001;
        bad[10].availabilityBps = 4;
        bad[11].availabilityBps = 101;
        bad[12].bondShareBps = 999;
        bad[13].bondShareBps = 5_001;
        for (uint256 i; i < bad.length; i++) {
            vm.prank(DAO);
            vm.expectRevert(Governed.OutOfBounds.selector);
            registry.proposePolicy(bad[i]);
        }
    }

    function test_gov_aGovernedPanelStartsInsideItsBounds() public {
        ArbiterRegistry.Policy memory p = _current();
        p.commitWindow = 1 hours;
        vm.expectRevert(Governed.OutOfBounds.selector);
        new ArbiterRegistry(
            address(escrow), address(token), p, DAO, address(vault), address(0), address(0), bytes32(0), address(0)
        );
    }

    /// The id is the policy in force: any change moves it, and changing back restores it.
    function testFuzz_gov_theIdFollowsThePolicyInForce(uint64 commit, uint16 availability, uint16 share) public {
        ArbiterRegistry.Policy memory p = _current();
        p.commitWindow = uint64(bound(commit, 1 days, 7 days));
        p.availabilityBps = uint16(bound(availability, 5, 100));
        p.bondShareBps = uint16(bound(share, 1_000, 5_000));
        vm.assume(!_sameTerms(p, _current()));
        bytes32 before = registry.packageId();
        _propose(p);
        vm.warp(registry.pendingAt());
        registry.enactPolicy();
        assertTrue(registry.packageId() != before, "a new policy is a new id");
        _propose(_current());
        vm.warp(registry.pendingAt());
        registry.enactPolicy();
        assertEq(registry.packageId(), before, "the same policy is the same id");
    }

    // --- the deals -----------------------------------------------------------------------------------

    /// Bound under the old terms and prices, decided and paid under them: the new windows, slash and share never
    /// reach a live case, and the kernel still finds its court.
    function test_gov_aLiveCaseKeepsTheTermsAndPricesItWasBoundUnder() public {
        _propose(_next());
        vm.warp(registry.pendingAt() - 1 hours);
        (bytes32 id,) = _openCourt(1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        registry.enactPolicy();
        assertEq(registry.commitWindow(), 2 days);

        _vote(id, 0, 2);
        _vote(id, 1, 2); // the third seat abstains
        (,,, uint64 openedAt) = registry.caseOf(id);
        vm.warp(openedAt + COMMIT); // the old commit window is over: reveals open
        _reveal(id, 0, 2);
        _reveal(id, 1, 2);
        vm.warp(openedAt + COMMIT + REVEAL); // old answer-by: decided, though the new terms would still be counting
        assertEq(registry.readRuling(id), 2);
        escrow.readRuling(id);
        registry.settle(id);
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        (uint256 bond,,,) = registry.arbiterOf(arbs[2]);
        assertEq(bond, BOND - lock * ABSTAIN_BPS / 10_000, "the old slash, not the new one");
        assertEq(registry.creditOf(arbs[0]), SHARE / 2 + _avail(), "the old share and availability");
        assertEq(registry.creditOf(arbs[1]), SHARE / 2 + _avail());
        assertEq(escrow.pricesOf(id).courtBondShareBps, SHARE_BPS, "the kernel kept the signed share");
    }

    /// The deal named the panel's old id: once the policy moves, that id resolves to nothing, and the deal does not
    /// activate. Nobody is bound to terms or prices they did not see.
    function test_gov_aDealSignedUnderTheOldPolicyDoesNotActivate() public {
        DealTerms memory t = _panelTerms();
        t.arbitrationDuration = 5 days;
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        PackageData memory data;
        data.court = _courtData(id, arbs, holderPk, providerPk);
        _enactNext();
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", _panelMods(), data);
    }

    function test_gov_aDealBoundAfterTheChangeGetsTheNewTermsAndPrices() public {
        _enactNext();
        DealTerms memory t = _panelTerms();
        t.arbitrationDuration = 4 days + 1 hours;
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        PackageData memory data;
        data.court = _courtData(id, arbs, holderPk, providerPk);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        uint256 registryBefore = token.balanceOf(address(registry));
        escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", _panelMods(), data);
        (,, uint256 lock,) = registry.caseOf(id);
        assertEq(lock, PRINCIPAL * 2_000 / 10_000, "the new lock");
        assertEq(token.balanceOf(address(registry)) - registryBefore, PRINCIPAL * 120 / 10_000, "the new availability");
        assertEq(escrow.pricesOf(id).courtBondShareBps, 1_500, "the new share");

        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        vm.warp(vm.getBlockTimestamp() + COMMIT + 1 hours); // past the old commit window, inside the new one
        _vote(id, 0, 1);
    }

    /// New windows longer than the deal's arbitration clock are refused at bind, as any windows are.
    function test_gov_newWindowsStillCloseBeforeTheKernelClock() public {
        _enactNext();
        _expectBindRevert(arbs, ArbiterRegistry.WindowsTooLong.selector);
    }
}
