// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms} from "../src/libraries/Types.sol";
import {Clocks} from "../src/libraries/Clocks.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract ClaimTest is BaseTest {
    function test_claim_afterReleaseDeadline() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_claim_beforeDeadlineReverts() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.expectRevert(Clocks.TooEarly.selector);
        escrow.claim(id);
    }

    function test_claim_revertsIfNotFiatSent() public {
        bytes32 id = _activateP2P(1, 1);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.claim(id);
    }

    function test_openDisputed_strictlyBeforeReleaseDeadline() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.warp(block.timestamp + 100);

        vm.prank(holder);
        vm.expectRevert(Clocks.TooLate.selector);
        escrow.openDisputed(id);

        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
    }
}
