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
    PackageData
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {IBondVault} from "../src/packages/interfaces/IBondVault.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {BaseTest} from "./Base.t.sol";

/// @title The tribunal: one or three arbiters the parties chose while they still cooperated
/// @notice PROTOCOLO.md Anexo R, 2026-09-28/29. One permissionless registry; arbiters bond, and each deal locks a
///         share of their bond from activation. The panel is signed by both parties and accepted by the three
///         arbiters, all before the principal is in custody. Votes are committed then revealed; one vote is an
///         answer; nobody answering is the Holder's by default. A deal with a panel carries both sides' bonds
///         (Anexo R, 2026-10-05), and opening the court costs nothing: the panel is paid out of the bonds. Who
///         earns what:
///           * the bond share (30% of the loser's lock): split among the arbiters who voted with the ruling —
///             all three when unanimous, the dissenter nothing —, or to the winner if nobody voted. If the
///             parties settle while the court is open, each leaves half of it and all three are paid;
///           * the availability fee (0.2% each): earned by an arbiter if the deal ended without a dispute, or
///             with one if the arbiter voted; unearned, it goes back to the Holder;
///           * an abstention costs part of the arbiter's lock; all three abstaining costs all of it. A slash
///             goes to the side the ruling went against — the one who lost without being heard.
contract ArbiterRegistryTest is BaseTest {
    uint256 internal constant AVAIL_BPS = 20; // per arbiter
    uint256 internal constant LOCK_BPS = 1_000; // 10% of the principal locked per arbiter per deal
    uint256 internal constant ABSTAIN_BPS = 5_000; // a lone abstainer loses half its lock
    uint256 internal constant SHARE_BPS = 3_000;
    /// The loser's lock is 10% of the principal; the court's share of it, 30%.
    uint256 internal constant SHARE = (PRINCIPAL / 10) * SHARE_BPS / 10_000;
    uint64 internal constant COMMIT = 1 days;
    uint64 internal constant REVEAL = 1 days;
    uint64 internal constant EXIT_DELAY = 7 days;
    uint256 internal constant BOND = PRINCIPAL; // room for several deals

    ArbiterRegistry internal registry;
    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");
    uint256[3] internal pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
    address[3] internal arbs;

    /// @dev Frozen terms here; `PanelGovernanceTest` runs this whole suite again under a governor.
    function _governor() internal view virtual returns (address) {
        return address(0);
    }

    function setUp() public virtual override {
        super.setUp();
        passport = new PassportMock();
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        reputation = new Reputation(passport, address(0xFEE), 0, 0, 0, 0, address(escrow));
        vault = new BondVault(address(escrow), address(0xdeaD), passport);
        registry = new ArbiterRegistry(
            address(escrow),
            address(token),
            ArbiterRegistry.Policy(
                COMMIT, REVEAL, EXIT_DELAY, uint16(LOCK_BPS), uint16(ABSTAIN_BPS), uint16(AVAIL_BPS), uint16(SHARE_BPS)
            ),
            _governor(),
            address(vault),
            address(0),
            address(0),
            bytes32(0),
            address(0)
        );
        for (uint256 i; i < 3; i++) {
            arbs[i] = vm.addr(pks[i]);
            token.mint(arbs[i], BOND);
            vm.startPrank(arbs[i]);
            token.approve(address(registry), type(uint256).max);
            registry.deposit(BOND);
            registry.setEncryptionKey(keccak256(abi.encode("x25519", i)));
            vm.stopPrank();
        }
        token.mint(holder, PRINCIPAL * 10); // availability fees on top of principals
        // Both sides' bonds, for several deals.
        token.mint(holder, PRINCIPAL);
        token.mint(provider, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        vm.prank(holder);
        vault.deposit(SUB_H, address(token), PRINCIPAL);
        vm.prank(provider);
        vault.deposit(SUB_P, address(token), PRINCIPAL);
    }

    // --- activation ------------------------------------------------------------------------------------

    function test_bind_locksEachArbitersShare_andHoldsTheAvailability() public {
        (bytes32 id,) = _activate(1);
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        for (uint256 i; i < 3; i++) {
            (uint256 bond, uint256 locked,,) = registry.arbiterOf(arbs[i]);
            assertEq(bond, BOND);
            assertEq(locked, lock, "a share of the bond is committed from activation");
            assertEq(registry.statsOf(arbs[i]).assigned, 1);
        }
        assertEq(token.balanceOf(address(registry)), 3 * BOND + 3 * _avail(), "the availability waits in the court");
        assertTrue(registry.available(id));
        (address[3] memory panel,,,) = registry.caseOf(id);
        assertEq(panel[0], arbs[0]);
    }

    function test_bind_refusesAPartyAsArbiter() public {
        address[3] memory panel = [arbs[0], arbs[1], holder];
        _expectBindRevert(panel, ArbiterRegistry.PartyOnPanel.selector);
    }

    function test_bind_refusesTheSameArbiterTwice() public {
        address[3] memory panel = [arbs[0], arbs[1], arbs[1]];
        _expectBindRevert(panel, ArbiterRegistry.PanelNotDistinct.selector);
    }

    function test_bind_refusesAPanelTheProviderNeverSigned() public {
        DealTerms memory t = _panelTerms();
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        bytes memory court = _courtData(id, arbs, holderPk, holderPk); // the Provider's slot signed by the Holder
        _expectActivationRevert(t, court, ArbiterRegistry.BadSignature.selector);
    }

    function test_bind_refusesAnArbiterWithoutCapacity() public {
        vm.prank(arbs[2]);
        registry.requestExit(BOND); // all of it on its way out: nothing left to commit
        DealTerms memory t = _panelTerms();
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        bytes memory court = _courtData(id, arbs, holderPk, providerPk);
        _expectActivationRevert(t, court, ArbiterRegistry.NoCapacity.selector);
    }

    /// The evidence reaches an arbiter sealed to its key (PROTOCOLO.md §E.3.14.4): one who never published a key
    /// could be shown nothing, so it cannot sit.
    function test_bind_refusesAnArbiterWithoutAnEncryptionKey() public {
        pks[2] = 0xA9;
        arbs[2] = vm.addr(pks[2]);
        token.mint(arbs[2], BOND);
        vm.startPrank(arbs[2]);
        token.approve(address(registry), type(uint256).max);
        registry.deposit(BOND);
        vm.stopPrank();
        _expectBindRevert(arbs, ArbiterRegistry.NoEncryptionKey.selector);
    }

    function test_encryptionKey_isPublishedAndRotated_butNeverZero() public {
        bytes32 next = keccak256("x25519 rotated");
        vm.expectEmit(address(registry));
        emit ArbiterRegistry.EncryptionKeySet(arbs[0], next);
        vm.prank(arbs[0]);
        registry.setEncryptionKey(next);
        assertEq(registry.encryptionKeyOf(arbs[0]), next);

        vm.prank(arbs[0]);
        vm.expectRevert(ArbiterRegistry.NoEncryptionKey.selector);
        registry.setEncryptionKey(bytes32(0));
        assertEq(registry.encryptionKeyOf(arbs[0]), next, "a key is replaced, never withdrawn");
    }

    function test_bind_refusesWindowsLongerThanTheArbitrationClock() public {
        DealTerms memory t = _panelTerms();
        t.arbitrationDuration = COMMIT + REVEAL; // the court must rule strictly before the kernel's clock
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        bytes memory court = _courtData(id, arbs, holderPk, providerPk);
        _expectActivationRevert(t, court, ArbiterRegistry.WindowsTooLong.selector);
    }

    // --- the panel is paid out of the bonds (Anexo R, 2026-10-05) ----------------------------------------

    /// No bonds, no panel: the share the arbiters are paid with has to exist before anyone can fight.
    function test_bind_refusesADealWithoutTheBondsOfItsVault() public {
        DealTerms memory t = _panelTerms();
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = passport.packageId();
        ids[1] = reputation.packageId();
        ids[2] = registry.packageId();
        t.packageIds = _sortIds(ids);
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        bytes memory court = _courtData(id, arbs, holderPk, providerPk);
        PackageMods memory mods = _panelMods();
        mods.bonds = address(0);
        PackageData memory data;
        data.court = court;
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(ArbiterRegistry.BondsRequired.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods, data);
    }

    function test_policy_noDisputeFee_aSignedBondShare() public view {
        assertEq(registry.contestFee(), 0, "opening the court costs nothing");
        assertEq(registry.bondShareBps(), SHARE_BPS);
        assertEq(registry.bondVault(), address(vault));
    }

    function test_openCourt_chargesTheOpenerNothing() public {
        (bytes32 id,) = _activate(1);
        _markFiat(id);
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        escrow.openCourt(id);
        assertEq(token.balanceOf(holder), before);
    }

    /// The share is in the vault only once the kernel disposed of the bonds. A settle before that would pay the
    /// arbiters nothing for good, so it waits.
    function test_settle_waitsForTheBondDisposal() public {
        (bytes32 id,) = _openCourt(1);
        _voteAll(id, [uint8(2), 2, 2]);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(IBondVault.slash.selector), "down");
        escrow.readRuling(id);
        vm.expectRevert(ArbiterRegistry.BondsPending.selector);
        registry.settle(id);
        vm.clearMockedCalls();
        escrow.retryPostTerminal(id);
        registry.settle(id);
        _assertSolvent();
        assertEq(registry.creditOf(arbs[0]), SHARE / 3 + _avail());
    }

    // --- no dispute ------------------------------------------------------------------------------------

    function test_noDispute_eachArbiterEarnsItsAvailability() public {
        (bytes32 id,) = _activate(1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        registry.settle(id);
        _assertSolvent();
        for (uint256 i; i < 3; i++) {
            assertEq(registry.creditOf(arbs[i]), _avail(), "earned by standing by");
            (, uint256 locked,,) = registry.arbiterOf(arbs[i]);
            assertEq(locked, 0, "the lock comes back");
        }
        vm.expectRevert(ArbiterRegistry.AlreadySettled.selector);
        registry.settle(id);
    }

    function test_settle_waitsForTheDealToEnd() public {
        (bytes32 id,) = _activate(1);
        vm.expectRevert(ArbiterRegistry.DealStillLive.selector);
        registry.settle(id);
    }

    // --- the fight -------------------------------------------------------------------------------------

    function test_unanimous_rulingSplitsTheBondShareAmongAllThree() public {
        (bytes32 id,) = _openCourt(1);
        _voteAll(id, [uint8(2), 2, 2]);
        vm.warp(block.timestamp + REVEAL);
        escrow.readRuling(id);
        (Status s,, uint256 pAmt) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertGt(pAmt, 0, "the Provider won");
        registry.settle(id);
        _assertSolvent();
        for (uint256 i; i < 3; i++) {
            assertEq(registry.creditOf(arbs[i]), SHARE / 3 + _avail(), "a third of the share and the availability");
            assertEq(registry.statsOf(arbs[i]).withRuling, 1);
        }
    }

    function test_twoToOne_theDissenterEarnsNoShare() public {
        (bytes32 id,) = _openCourt(1);
        _voteAll(id, [uint8(1), 1, 2]);
        vm.warp(block.timestamp + REVEAL);
        escrow.readRuling(id);
        (, uint256 hAmt,) = escrow.settlementOf(id);
        assertEq(hAmt, PRINCIPAL, "the Holder won 2 to 1");
        registry.settle(id);
        _assertSolvent();
        assertEq(registry.creditOf(arbs[0]), SHARE / 2 + _avail());
        assertEq(registry.creditOf(arbs[1]), SHARE / 2 + _avail());
        assertEq(registry.creditOf(arbs[2]), _avail(), "voted, so available; dissented, so no share");
    }

    function test_aLoneAbstainer_losesHalfItsLock_toTheLosingSide_andItsAvailabilityToTheHolder() public {
        (bytes32 id,) = _openCourt(1);
        _vote(id, 0, 2);
        _vote(id, 1, 2);
        vm.warp(block.timestamp + COMMIT);
        _reveal(id, 0, 2);
        _reveal(id, 1, 2);
        vm.warp(block.timestamp + REVEAL);
        escrow.readRuling(id);
        uint256 holderBefore = registry.creditOf(holder);
        registry.settle(id);
        _assertSolvent();
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        uint256 slash = lock * ABSTAIN_BPS / 10_000;
        (uint256 bond,,,) = registry.arbiterOf(arbs[2]);
        assertEq(bond, BOND - slash, "an abstention costs bond");
        assertEq(registry.creditOf(holder), holderBefore + slash + _avail(), "the side the ruling went against");
        assertEq(registry.creditOf(arbs[2]), 0, "nothing earned");
        assertEq(registry.statsOf(arbs[2]).abstentions, 1);
    }

    function test_allAbstain_theHolderWins_eachLosesItsLock_toTheProvider_andTheShareGoesToTheWinner() public {
        (bytes32 id,) = _openCourt(1);
        vm.warp(block.timestamp + COMMIT + REVEAL);
        assertEq(registry.readRuling(id), 1, "nobody answered: the Holder's by default");
        escrow.readRuling(id);
        (, uint256 hAmt,) = escrow.settlementOf(id);
        assertEq(hAmt, PRINCIPAL);
        registry.settle(id);
        _assertSolvent();
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        for (uint256 i; i < 3; i++) {
            (uint256 bond, uint256 locked,,) = registry.arbiterOf(arbs[i]);
            assertEq(bond, BOND - lock, "all of the deal's lock");
            assertEq(locked, 0);
        }
        assertEq(registry.creditOf(provider), 3 * lock, "the Provider lost without being heard");
        assertEq(
            registry.creditOf(holder),
            SHARE + 3 * _avail(),
            "nobody earned the share: the winner's, with the availability"
        );
    }

    function test_aTieIsTheHoldersDefault() public {
        (bytes32 id,) = _openCourt(1);
        _vote(id, 0, 1);
        _vote(id, 1, 2);
        vm.warp(block.timestamp + COMMIT);
        _reveal(id, 0, 1);
        _reveal(id, 1, 2);
        vm.warp(block.timestamp + REVEAL);
        assertEq(registry.readRuling(id), 1);
    }

    /// One time to answer (Anexo R, 2026-09-29): a panel that has all revealed has decided, and anyone can
    /// close the deal on it without waiting out the four days.
    function test_everySeatRevealed_decidesAtOnce() public {
        (bytes32 id,) = _openCourt(1);
        _voteAll(id, [uint8(2), 2, 2]);
        assertEq(registry.readRuling(id), 2);
        vm.prank(address(0xdead));
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
    }

    /// While a seat can still reveal there is no ruling. At the end of the time to answer, whoever did not
    /// reveal abstained, and anyone can close the case on that.
    function test_noRulingWhileASeatCanStillReveal_thenAnyoneClosesOnTheAbstention() public {
        (bytes32 id,) = _openCourt(1);
        for (uint256 i; i < 3; i++) {
            _vote(id, i, 2);
        }
        _reveal(id, 0, 2);
        _reveal(id, 1, 2);
        assertEq(registry.readRuling(id), 0, "the third seat can still reveal");
        vm.warp(block.timestamp + COMMIT + REVEAL);
        vm.prank(address(0xdead));
        escrow.readRuling(id);
        registry.settle(id);
        assertEq(registry.statsOf(arbs[2]).abstentions, 1);
        _assertSolvent();
    }

    /// Reveals open early only once every vote is fixed: from then no commit moves, so nobody reveals into a
    /// vote that could still change.
    function test_revealsOpenEarly_onlyOnceEveryVoteIsFixed() public {
        (bytes32 id,) = _openCourt(1);
        _vote(id, 0, 2);
        _vote(id, 1, 1);
        vm.prank(arbs[0]);
        vm.expectRevert(ArbiterRegistry.WindowClosed.selector);
        registry.reveal(id, 2, bytes32(uint256(0)));

        _vote(id, 2, 2);
        _reveal(id, 0, 2);
        vm.prank(arbs[1]);
        vm.expectRevert(ArbiterRegistry.WindowClosed.selector);
        registry.commit(id, keccak256(abi.encode(id, arbs[1], uint8(2), bytes32(uint256(1)))));
    }

    /// Agreed while the court was open: the arbiters are paid as if they had ruled unanimously.
    function test_settledDuringTheFight_eachSideLeavesHalfTheShare_paidAsUnanimous() public {
        (bytes32 id,) = _openCourt(1);
        _mutualCancel(id, 11, 12);
        registry.settle(id);
        _assertSolvent();
        for (uint256 i; i < 3; i++) {
            assertEq(registry.creditOf(arbs[i]), SHARE / 3 + _avail());
        }
    }

    /// Disputed but never escalated: nobody was asked to decide, so nothing was earned from the fight.
    function test_disputedButNeverEscalated_refundsTheAvailability_andTakesNoShare() public {
        (bytes32 id,) = _activate(1);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        _mutualCancel(id, 11, 12);
        registry.settle(id);
        _assertSolvent();
        assertEq(registry.creditOf(holder), 3 * _avail());
        assertEq(vault.available(SUB_H, address(token)), PRINCIPAL, "nobody was asked: both locks whole");
        assertEq(vault.available(SUB_P, address(token)), PRINCIPAL);
        for (uint256 i; i < 3; i++) {
            assertEq(registry.creditOf(arbs[i]), 0);
        }
    }

    // --- commit / reveal -------------------------------------------------------------------------------

    function test_votesAreHiddenUntilRevealed() public {
        (bytes32 id,) = _openCourt(1);
        vm.prank(arbs[0]);
        registry.commit(id, keccak256(abi.encode(id, arbs[0], uint8(2), bytes32("salt"))));
        vm.prank(arbs[1]);
        vm.expectRevert(ArbiterRegistry.BadCommit.selector);
        registry.commit(id, bytes32(0));
        vm.prank(holder);
        vm.expectRevert(ArbiterRegistry.NotOnPanel.selector);
        registry.commit(id, bytes32(uint256(1)));
        vm.warp(block.timestamp + COMMIT);
        vm.prank(arbs[0]);
        vm.expectRevert(ArbiterRegistry.BadReveal.selector);
        registry.reveal(id, 1, bytes32("salt")); // not what was committed
        vm.prank(arbs[0]);
        registry.reveal(id, 2, bytes32("salt"));
    }

    function test_noCommitAfterTheWindow() public {
        (bytes32 id,) = _openCourt(1);
        vm.warp(block.timestamp + COMMIT);
        vm.prank(arbs[0]);
        vm.expectRevert(ArbiterRegistry.WindowClosed.selector);
        registry.commit(id, bytes32(uint256(1)));
    }

    // --- the bond ---------------------------------------------------------------------------------------

    function test_exit_waitsTheDelay_andNeverTouchesALockedBond() public {
        (bytes32 id,) = _activate(1);
        vm.startPrank(arbs[0]);
        vm.expectRevert(ArbiterRegistry.NoCapacity.selector);
        registry.requestExit(BOND); // part of it is committed to a live deal
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        registry.requestExit(BOND - lock);
        vm.expectRevert(ArbiterRegistry.TooEarly.selector);
        registry.exit();
        vm.warp(block.timestamp + EXIT_DELAY);
        registry.exit();
        vm.stopPrank();
        assertEq(token.balanceOf(arbs[0]), BOND - lock);
        id;
    }

    function test_credits_areWithdrawn() public {
        (bytes32 id,) = _activate(1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        registry.settle(id);
        _assertSolvent();
        vm.prank(arbs[0]);
        registry.withdrawCredit();
        assertEq(token.balanceOf(arbs[0]), _avail());
    }

    // --- helpers ----------------------------------------------------------------------------------------

    // --- a panel of one (Anexo R, 2026-09-29) -------------------------------------------------------------

    function _solo() internal view returns (address[3] memory) {
        return [arbs[0], address(0), address(0)];
    }

    /// The Holder paid availability for three, as the court's signed share says; the two empty seats are hers
    /// again the moment the panel is bound, as a credit — nothing in the pool or the kernel has to know the size.
    function test_soloPanel_locksOneArbiter_andCreditsTheUnusedAvailabilityBack() public {
        _activateWith(1, _solo());
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        (, uint256 locked,,) = registry.arbiterOf(arbs[0]);
        assertEq(locked, lock);
        for (uint256 i = 1; i < 3; i++) {
            (, locked,,) = registry.arbiterOf(arbs[i]);
            assertEq(locked, 0, "an empty seat locks nobody");
            assertEq(registry.statsOf(arbs[i]).assigned, 0);
        }
        assertEq(registry.creditOf(holder), 2 * _avail(), "two seats' availability, back at once");
        assertEq(token.balanceOf(address(registry)), 3 * BOND + 3 * _avail(), "one seat held, two owed back");
    }

    function test_soloPanel_noDispute_theArbiterEarnsOneShare() public {
        (bytes32 id,) = _activateWith(1, _solo());
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        registry.settle(id);
        _assertSolvent();
        assertEq(registry.creditOf(arbs[0]), _avail());
        assertEq(registry.creditOf(holder), 2 * _avail());
    }

    function test_soloPanel_itsVoteIsTheRuling_andEarnsTheWholeShare() public {
        (bytes32 id,) = _activateWith(1, _solo());
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        _vote(id, 0, 2);
        vm.warp(block.timestamp + COMMIT);
        _reveal(id, 0, 2);
        vm.warp(block.timestamp + REVEAL);
        assertEq(registry.readRuling(id), 2, "one arbiter, one answer");
        escrow.readRuling(id);
        registry.settle(id);
        _assertSolvent();
        assertEq(registry.creditOf(arbs[0]), SHARE + _avail());
        assertEq(registry.statsOf(arbs[0]).disputes, 1);
        assertEq(registry.statsOf(arbs[1]).disputes, 0, "an empty seat is nobody's dispute");
    }

    /// A lone arbiter who abstains is the whole panel abstaining: all of its lock, and the Holder's default.
    function test_soloPanel_abstaining_losesTheWholeLock_andTheHolderWins() public {
        (bytes32 id,) = _activateWith(1, _solo());
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        vm.warp(block.timestamp + COMMIT + REVEAL);
        assertEq(registry.readRuling(id), 1);
        escrow.readRuling(id);
        registry.settle(id);
        _assertSolvent();
        uint256 lock = PRINCIPAL * LOCK_BPS / 10_000;
        (uint256 bond,,,) = registry.arbiterOf(arbs[0]);
        assertEq(bond, BOND - lock);
        assertEq(registry.creditOf(provider), lock, "to the side that lost without being heard");
        assertEq(registry.creditOf(holder), SHARE + 3 * _avail(), "no decision: the share and all availability");
    }

    /// One or three, never two: with the Holder's default on a tie, an even panel hands the Holder a
    /// head start nobody chose. And the arbiters fill the seats in order.
    function test_bind_refusesAnyOtherPanelSize() public {
        _expectBindRevert([arbs[0], arbs[1], address(0)], ArbiterRegistry.BadPanelSize.selector);
        _expectBindRevert([arbs[0], address(0), arbs[2]], ArbiterRegistry.BadPanelSize.selector);
        _expectBindRevert([address(0), arbs[1], arbs[2]], ArbiterRegistry.BadPanelSize.selector);
        _expectBindRevert([address(0), address(0), address(0)], ArbiterRegistry.BadPanelSize.selector);
    }

    /// @dev After every settlement the registry holds exactly the bonds and the credits it owes: no fee is held for
    ///      a settled deal, and no path created or lost value.
    function _assertSolvent() internal view {
        uint256 owed;
        for (uint256 i; i < 3; i++) {
            (uint256 bond,,,) = registry.arbiterOf(arbs[i]);
            owed += bond + registry.creditOf(arbs[i]);
        }
        owed += registry.creditOf(holder) + registry.creditOf(provider);
        assertEq(token.balanceOf(address(registry)), owed, "registry balance != bonds + credits");
    }

    function _avail() internal pure returns (uint256) {
        return PRINCIPAL * AVAIL_BPS / 10_000;
    }

    function _panelTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.arbitrationDuration = COMMIT + REVEAL + 1 hours;
        t.packageIds = new bytes32[](4);
        t.packageIds[0] = passport.packageId();
        t.packageIds[1] = reputation.packageId();
        t.packageIds[2] = vault.packageId();
        t.packageIds[3] = registry.packageId();
        t.packageIds = _sortIds(t.packageIds);
    }

    function _panelMods() internal view returns (PackageMods memory mods) {
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(vault);
        mods.court = address(registry);
    }

    function _appointment(bytes32 id, address[3] memory panel) internal view returns (bytes32) {
        return registry.appointmentDigest(id, panel);
    }

    function _courtData(bytes32 id, address[3] memory panel, uint256 holderKey, uint256 providerKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _appointment(id, panel);
        bytes[3] memory accepts;
        for (uint256 i; i < 3; i++) {
            uint256 key;
            for (uint256 k; k < 3; k++) {
                if (arbs[k] == panel[i]) key = pks[k];
            }
            accepts[i] = key == 0 ? bytes("") : _sign(digest, key);
        }
        return abi.encode(panel, _sign(digest, holderKey), _sign(digest, providerKey), accepts);
    }

    function _activate(uint256 nonce) internal returns (bytes32 id, DealTerms memory t) {
        return _activateWith(nonce, arbs);
    }

    function _activateWith(uint256 nonce, address[3] memory panel) internal returns (bytes32 id, DealTerms memory t) {
        t = _panelTerms();
        bytes32 expected = Consent.dealId(escrow.domainSeparator(), t, nonce, nonce, 0);
        PackageMods memory mods = _panelMods();
        PackageData memory data;
        data.court = _courtData(expected, panel, holderPk, providerPk);
        HolderAuthorization memory ha = _holderAuth(t, nonce);
        ProviderAgreement memory pa = _providerAuth(t, nonce);
        ControllerAcceptance memory ca;
        id = escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods, data);
        assertEq(id, expected);
    }

    function _openCourt(uint256 nonce) internal returns (bytes32 id, DealTerms memory t) {
        (id, t) = _activate(nonce);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
    }

    function _vote(bytes32 id, uint256 i, uint8 vote) internal {
        vm.prank(arbs[i]);
        registry.commit(id, keccak256(abi.encode(id, arbs[i], vote, bytes32(i))));
    }

    function _reveal(bytes32 id, uint256 i, uint8 vote) internal {
        vm.prank(arbs[i]);
        registry.reveal(id, vote, bytes32(i));
    }

    function _voteAll(bytes32 id, uint8[3] memory votes) internal {
        for (uint256 i; i < 3; i++) {
            _vote(id, i, votes[i]);
        }
        vm.warp(block.timestamp + COMMIT);
        for (uint256 i; i < 3; i++) {
            _reveal(id, i, votes[i]);
        }
    }

    function _expectBindRevert(address[3] memory panel, bytes4 selector) internal {
        DealTerms memory t = _panelTerms();
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        bytes memory court = _courtData(id, panel, holderPk, providerPk);
        _expectActivationRevert(t, court, selector);
    }

    function _expectActivationRevert(DealTerms memory t, bytes memory court, bytes4 selector) internal {
        PackageMods memory mods = _panelMods();
        PackageData memory data;
        data.court = court;
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods, data);
    }
}
