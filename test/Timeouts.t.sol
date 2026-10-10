// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms} from "../src/libraries/Types.sol";
import {Clocks} from "../src/libraries/Clocks.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract TimeoutsTest is BaseTest {
    function test_timeoutFiat_durationZero_eligibleImmediately() public {
        DealTerms memory terms = _p2pTerms();
        terms.fiatDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        escrow.timeoutFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_timeoutFiat_beforeDeadlineReverts() public {
        bytes32 id = _activateP2P(1, 1);
        vm.expectRevert(Clocks.TooEarly.selector);
        escrow.timeoutFiat(id);
    }

    function test_timeoutFiat_anyone() public {
        DealTerms memory terms = _p2pTerms();
        terms.fiatDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(address(0xDEAD));
        escrow.timeoutFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
    }

    function test_timeoutFiat_racesMarkFiat_firstWins() public {
        DealTerms memory terms = _p2pTerms();
        terms.fiatDuration = 100;
        bytes32 timeoutWins = _activateP2PWith(terms, 1, 1);
        token.mint(holder, PRINCIPAL);
        bytes32 markWins = _activateP2PWith(terms, 2, 2);

        vm.warp(block.timestamp + 100);

        escrow.timeoutFiat(timeoutWins);
        vm.prank(provider);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.markFiat(timeoutWins);

        vm.prank(provider);
        escrow.markFiat(markWins);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.timeoutFiat(markWins);
    }
}
