// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @title The reputation curve
/// @notice Pins the ladder table of PROTOCOLO.md §E.3.14.7 against the code that produces it.
/// @dev `script/ReputationLadder.s.sol` walks this on a real chain and narrates it, which is how you
///      learn what the package does. This is the fast half: the spec now states "five deals at the
///      cap reach T2, twenty-one reach T5" as a measured fact, and a measured fact in a document
///      rots silently unless something fails when it stops being true.
///
///      The shape worth remembering: a deal AT THE CAP is worth two points, because the T1 cap is
///      exactly the score's unit of volume (+1 for closing, +1 for the volume). So the climb
///      accelerates on its own — a higher cap means more volume per deal.
contract ReputationCurveTest is Test {
    /// @dev A fresh deal id / counterparty per call: these tests predate the 2026-09-23 rule that credit
    ///      is once per counterparty, and they all mean "another deal with somebody new". The ones that
    ///      mean "the same somebody again" say so by passing a fixed tag.
    uint256 private _tagNonce;

    function _dealTag() internal returns (bytes32) {
        return keccak256(abi.encode("deal", ++_tagNonce));
    }

    function _cpTag() internal returns (bytes32) {
        return keccak256(abi.encode("counterparty", ++_tagNonce));
    }
    Reputation internal rep;
    TestToken internal token;
    PassportMock internal passport;
    bytes32 internal constant SUBJECT = keccak256("curve");
    address internal operator = address(0xAA);
    address internal wallet = address(0xA11CE);

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        passport.setHuman(wallet, SUBJECT);
        rep = new Reputation(passport, address(0xFEE), 0, 0, 0, 0, operator);
    }

    /// A deal at the cap with somebody NEW, a day after the last one. Both halves matter since
    /// 2026-09-23: credit is once per counterparty, and at most sixteen credited deals per epoch.
    /// Twenty-one deals at the top of the ladder were never a weekend's work; now the code says so.
    function _closeAtCap(IReputation.Close kind) internal returns (uint256 principal) {
        principal = rep.cap(SUBJECT, address(token), false);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), principal, address(0), "");
        rep.notifyTerminal(SUBJECT, _cpTag(), address(token), principal, kind);
        vm.stopPrank();
    }

    /// The same counterparty, again: this is the farm, and it is what stopped paying.
    function _closeAtCapWith(bytes32 counterparty, IReputation.Close kind) internal returns (uint256 principal) {
        principal = rep.cap(SUBJECT, address(token), false);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), principal, address(0), "");
        rep.notifyTerminal(SUBJECT, counterparty, address(token), principal, kind);
        vm.stopPrank();
    }

    function _cap() internal view returns (uint256) {
        return rep.cap(SUBJECT, address(token), false);
    }

    function _score() internal view returns (uint256) {
        return rep.score(SUBJECT, address(token));
    }

    /// The table in §E.3.14.7, row by row.
    function test_theLadderIsWhatTheSpecSays() public {
        assertEq(_score(), 0);
        assertEq(_cap(), 250e6, "T1");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 10, "five deals at the cap");
        assertEq(_cap(), 500e6, "T2");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 25, "ten deals");
        assertEq(_cap(), 1000e6, "T3");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 50, "fifteen deals");
        assertEq(_cap(), 2000e6, "T4");

        for (uint256 i = 0; i < 6; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 104, "twenty-one deals");
        // T5's base column tops at 5.000 (2026-09-23): unlimited exposure is the BOND column, so the
        // protocol's one uncapped position always has a live lock — 10% of itself — behind it.
        assertEq(_cap(), 5000e6, "T5 without bond");
        assertEq(rep.cap(SUBJECT, address(token), true), type(uint256).max, "T5 with bond: no limit");
    }

    /// A deal at the cap is worth two points and not one: the cap IS the unit.
    function test_aDealAtTheCapIsWorthTwo() public {
        _closeAtCap(IReputation.Close.Peaceful);
        assertEq(_score(), 2);
    }

    /// The cap is the most that can be OPEN at once, which is the thing people misread.
    function test_theCapIsConcurrentNotPerDeal() public {
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), 150e6, address(0), "");
        vm.expectRevert(Reputation.CapExceeded.selector);
        rep.admit(wallet, _dealTag(), address(token), 150e6, address(0), "");
        vm.stopPrank();
        assertEq(rep.inFlight(SUBJECT, address(token)), 150e6, "the first one is still holding it");
    }

    /// Slow to earn, fast to lose: five clean deals of work, one abandoned dispute, back to T1.
    function test_oneAbandonedDisputeCostsATier() public {
        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_cap(), 500e6, "T2");
        _closeAtCap(IReputation.Close.Stalemate); // the reading an abandoned dispute gives the opener
        assertEq(_score(), 5, "minus five");
        assertEq(_cap(), 250e6, "back to T1, in one deal");
    }

    /// The counterparty of an abandoned dispute gets the same credit as a clean trade. Worth pinning
    /// because it is an incentive, not an accident: it is why refusing to settle can pay.
    function test_theCounterpartyOfAnAbandonmentIsPaidLikeACleanTrade() public {
        bytes32 other = keccak256("counterparty");
        address otherWallet = address(0xB0B);
        passport.setHuman(otherWallet, other);
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), 250e6, address(0), "");
        rep.admit(otherWallet, _dealTag(), address(token), 250e6, address(0), "");
        rep.notifyTerminal(SUBJECT, _cpTag(), address(token), 250e6, IReputation.Close.Stalemate);
        rep.notifyTerminal(other, _cpTag(), address(token), 250e6, IReputation.Close.Peaceful);
        vm.stopPrank();
        assertEq(_score(), 0, "the opener lost five, floored at zero");
        assertEq(rep.score(other, address(token)), 2, "the counterparty gained a clean trade");
    }

    /// An arbitration loss is three times an abandonment, and a win costs nothing.
    function test_aVerdictWeighsMoreThanAClockRunningOut() public {
        for (uint256 i = 0; i < 10; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        uint256 before = _score();
        _closeAtCap(IReputation.Close.ArbLoss);
        assertEq(_score(), before - 15, "a proven loss is fifteen");

        uint256 mid = _score();
        _closeAtCap(IReputation.Close.ArbWin);
        assertEq(_score(), mid, "a win moves nothing: the volume is not credited either");
    }

    /// The farm, priced. Twenty-one deals with ONE counterparty — the two-identity cluster that used
    /// to buy the whole ladder for the cost of fees — now buys exactly one deal's worth of credit.
    function test_aClosedPairSaturatesAtOneDeal() public {
        bytes32 partner = keccak256("the other half of the cluster");
        for (uint256 i = 0; i < 21; i++) {
            _closeAtCapWith(partner, IReputation.Close.Peaceful);
        }
        assertEq(_score(), 2, "one credited deal, and no more");
        assertEq(_cap(), 250e6, "still T1");
    }

    /// And the asymmetry that makes it safe to do: what goes WRONG counts every time, however often
    /// you deal with the same person. Credit is once per counterparty; penalties have no such mercy.
    function test_penaltiesAreNotDeduplicated() public {
        bytes32 partner = keccak256("the same somebody");
        _closeAtCapWith(partner, IReputation.Close.Peaceful);
        assertEq(_score(), 2, "the first deal credits");
        _closeAtCapWith(partner, IReputation.Close.Stalemate);
        assertEq(_score(), 0, "a stalemate with the same partner still costs 5");
        _closeAtCapWith(partner, IReputation.Close.ArbLoss);
        (, uint32 pen,) = rep.stats(SUBJECT, address(token));
        assertEq(pen, 20, "and an arbitration loss still costs 15");
    }

    /// The rule is keyed per TOKEN, like the stats it moves — and like the private twin, where an
    /// account holds one leaf per token so its counterparty tree already lives inside it. A partner
    /// who vouched for you in one token has said nothing about another, and the credit only buys cap
    /// where it was earned, so the extra dimension is no shortcut into the tier that matters.
    function test_creditIsPerToken() public {
        TestToken other = new TestToken();
        bytes32 partner = keccak256("the same partner, another token");
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), 1, address(0), "");
        rep.notifyTerminal(SUBJECT, partner, address(token), 1, IReputation.Close.Peaceful);
        rep.admit(wallet, _dealTag(), address(other), 1, address(0), "");
        rep.notifyTerminal(SUBJECT, partner, address(other), 1, IReputation.Close.Peaceful);
        // The same partner again in the FIRST token earns nothing: that pair is spent there.
        rep.admit(wallet, _dealTag(), address(token), 1, address(0), "");
        rep.notifyTerminal(SUBJECT, partner, address(token), 1, IReputation.Close.Peaceful);
        vm.stopPrank();
        (uint32 inToken,,) = rep.stats(SUBJECT, address(token));
        (uint32 inOther,,) = rep.stats(SUBJECT, address(other));
        assertEq(inToken, 1, "one credit in the token it was earned in");
        assertEq(inOther, 1, "and one in the other, from the same partner");
    }

    /// The rate window: sixteen credited deals in an epoch, and the seventeenth earns nothing — not
    /// even later. A limit that let the credit come back tomorrow would only be a delay.
    function test_theSeventeenthDealOfADayEarnsNothing() public {
        vm.startPrank(operator);
        for (uint256 i = 0; i < 17; i++) {
            rep.admit(wallet, _dealTag(), address(token), 1, address(0), "");
            rep.notifyTerminal(SUBJECT, _cpTag(), address(token), 1, IReputation.Close.Peaceful);
        }
        vm.stopPrank();
        (uint32 credited,,) = rep.stats(SUBJECT, address(token));
        assertEq(credited, 16, "sixteen credited, one refused");
        // A day later the window reopens for NEW counterparties.
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(operator);
        rep.admit(wallet, _dealTag(), address(token), 1, address(0), "");
        rep.notifyTerminal(SUBJECT, _cpTag(), address(token), 1, IReputation.Close.Peaceful);
        vm.stopPrank();
        (uint32 after_,,) = rep.stats(SUBJECT, address(token));
        assertEq(after_, 17, "the window reopened");
    }
}
