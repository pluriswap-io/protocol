// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title A dispute nobody resolves, in a deal nobody gave a tribunal
/// @notice The Core dispute equilibrium (PROTOCOLO.md Anexo R, 2026-09-24).
/// @dev Two parties who sign a deal without ARBITRATION chose, together, to have nobody decide. When one of
///      them freezes the trade, the kernel makes sure that NO ONE can profit from the freeze:
///
///      * no split after a dispute — the only agreements left are all-or-nothing: mutual cancel (all to
///        the Holder) or co-signed release (all to the Provider). "Give me half or we both lose it" is not
///        an offer the kernel will execute;
///      * the clock burns everything — the principal to a dead address, both bonds to the sink, both
///        scores marked. Mutually assured destruction.
///
///      Together they make surrender every cheater's best reply. A Provider who marked fiat without paying
///      gets 0 by signing the cancel and loses his bond by waiting; a Holder who was paid and disputed gets
///      0 by signing the release and loses her bond (and the crypto she already sold) by waiting. The price
///      is stated rather than hidden: facing a spiteful cheater, or an honest partner in a genuine
///      disagreement, the principal is lost. That is the deal the parties signed when they chose no
///      tribunal, and it is why a deal that matters selects ARBITRATION.
contract DisputeDeadlockTest is BaseTest {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    function test_withoutATribunal_theClockBurnsThePrincipal() public {
        bytes32 id = _activateP2P(1, 2);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);

        vm.warp(block.timestamp + 7200);
        vm.expectEmit(address(escrow));
        emit Escrow.PrincipalBurned(id, PRINCIPAL);
        vm.prank(address(0xdead)); // permissionless, as every timeout is
        escrow.forceDisputeTimeout(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE), "nobody asked for a verdict, so there is none");
        assertEq(holderAmt, 0, "nobody profits from a freeze");
        assertEq(providerAmt, 0);
        assertEq(token.balanceOf(BURN), PRINCIPAL, "the principal is destroyed");
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(address(escrow)), 0, "nothing lingers in custody");
    }

    /// A Provider who never paid, faced with a dispute, is better off signing the cancel: the Holder gets
    /// everything back and the lie cost the liar its chance, not the victim's principal.
    function test_aLiarsBestReply_isTheCancel() public {
        bytes32 id = _activateP2P(3, 4);
        _markFiat(id); // a lie: no fiat moved
        vm.prank(holder);
        escrow.openDisputed(id);
        _mutualCancel(id, 5, 6);
        (Status st, uint256 holderAmt,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CANCELLED));
        assertEq(holderAmt, PRINCIPAL, "the victim is made whole");
    }

    /// A Holder who was paid and disputed anyway is better off signing the release: the Provider gets
    /// everything, as if the freeze had never happened.
    function test_anExtortionistsBestReply_isTheRelease() public {
        bytes32 id = _activateP2P(7, 8);
        _markFiat(id); // fiat really moved
        vm.prank(holder);
        escrow.openDisputed(id);
        _coSignedRelease(id, 9, 10);
        (Status st,, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RELEASED));
        assertEq(providerAmt, PRINCIPAL, "the victim is made whole");
    }

    /// The half-and-half a cheater would extract with the clock as a threat is not on the table.
    function test_noSplitAfterADispute() public {
        bytes32 id = _activateP2P(11, 12);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.expectRevert(Escrow.SplitAfterDispute.selector);
        this.splitExternally(id, 5000, 13, 14);
    }

    /// Before anybody disputes, a split is still an agreement without a fight, and still available.
    function test_aSplitBeforeTheDispute_isStillAnAgreement() public {
        bytes32 id = _activateP2P(15, 16);
        _markFiat(id);
        _mutualSplit(id, 4000, 17, 18);
        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_SPLIT));
        assertEq(providerAmt, PRINCIPAL * 4000 / 10_000);
        assertEq(holderAmt, PRINCIPAL - providerAmt);
    }

    /// The clock is still a clock.
    function test_beforeTheDeadline_nothingBurns() public {
        bytes32 id = _activateP2P(19, 20);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.expectRevert();
        escrow.forceDisputeTimeout(id);
    }

    function splitExternally(bytes32 id, uint16 bps, uint256 pn, uint256 cn) external {
        _mutualSplit(id, bps, pn, cn);
    }
}
