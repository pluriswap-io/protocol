// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {DealTerms, Status} from "../src/libraries/Types.sol";

/// @title Zero clocks
/// @notice What the kernel does when a signed duration is zero (PROTOCOLO.md §E.3.8).
/// @dev The kernel's only bound on a duration is `>= 0`, and that is the right line: the clocks
///      belong to the parties and the signature covers them. A kernel with a minimum would be a
///      kernel with an opinion about how long a bank transfer takes.
///
///      But a zero clock is not a short clock — it hands one side a free win, and all four are
///      reachable with terms both parties legitimately signed. These tests are the ground truth
///      behind the client-side review (`lab/src/consent/termsReview.ts`), which is the only thing
///      standing between a person and a signature that gives away their principal. If the kernel's
///      behaviour here ever changes, the review's claims are wrong and these fail first.
contract ZeroClocksTest is BaseTest {
    /// `fiatDuration = 0`: the refund timeout is due in the activation block.
    function test_zeroFiatDuration_cancelsBeforeTheProviderCanPay() public {
        DealTerms memory t = _p2pTerms();
        t.fiatDuration = 0;
        bytes32 id = _activateP2PWith(t, 1, 2);

        vm.prank(address(0xdead)); // permissionless, and nobody had to wait
        escrow.timeoutFiat(id);

        (Status st, uint256 holderAmt,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CANCELLED));
        assertEq(holderAmt, PRINCIPAL, "a Provider who already paid fiat has no escrow left");
    }

    /// `releaseDuration = 0`: mark and claim in one block, nothing proven.
    function test_zeroReleaseDuration_paysTheProviderInTheSameBlock() public {
        DealTerms memory t = _p2pTerms();
        t.releaseDuration = 0;
        bytes32 id = _activateP2PWith(t, 3, 4);

        vm.startPrank(provider);
        escrow.markFiat(id);
        escrow.claim(id);
        vm.stopPrank();

        (Status st,, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CLAIMED));
        assertEq(providerAmt, PRINCIPAL);
    }

    /// And the same zero removes the defence: `openDisputed` must be strictly before the deadline,
    /// which has already passed. The Holder does not even get the freeze.
    function test_zeroReleaseDuration_alsoRemovesTheFreeze() public {
        DealTerms memory t = _p2pTerms();
        t.releaseDuration = 0;
        bytes32 id = _activateP2PWith(t, 5, 6);
        _markFiat(id);

        vm.prank(holder);
        vm.expectRevert();
        escrow.openDisputed(id);
    }

    /// `disputeDuration = 0` in a deal without a tribunal: the freeze is an instant deadlock. There is no
    /// window to settle in, so opening the fight burns the principal in the block it is opened — the
    /// Holder's only defence destroys the deal, and with the official packages both sides are marked.
    function test_zeroDisputeDuration_deadlocksInstantly() public {
        DealTerms memory t = _p2pTerms();
        t.disputeDuration = 0;
        bytes32 id = _activateP2PWith(t, 7, 8);
        _markFiat(id);

        vm.prank(holder);
        escrow.openDisputed(id);
        vm.prank(address(0xdead)); // no warp: anyone, in the very next transaction
        escrow.forceDisputeTimeout(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE));
        assertEq(holderAmt, 0);
        assertEq(providerAmt, 0, "no window to settle in: burned at once");
    }
}
