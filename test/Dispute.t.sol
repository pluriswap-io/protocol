// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms} from "../src/libraries/Types.sol";
import {Clocks} from "../src/libraries/Clocks.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract DisputeTest is BaseTest {
    function _fiatSent(uint256 holderNonce, uint256 providerNonce) internal returns (bytes32 id) {
        id = _activateP2P(holderNonce, providerNonce);
        vm.prank(provider);
        escrow.markFiat(id);
    }

    function test_openDisputed_onlyController_fromFiatSent() public {
        bytes32 id = _fiatSent(1, 1);
        vm.prank(provider);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.openDisputed(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
    }

    function test_openDisputed_revertsFromFunded() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.openDisputed(id);
    }

    function test_openDisputed_once() public {
        bytes32 id = _fiatSent(1, 1);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.openDisputed(id);
    }

    function test_release_revertsWhileDisputed() public {
        bytes32 id = _fiatSent(1, 1);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
    }

    function test_claim_revertsWhileDisputed() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 100);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.claim(id);
    }

    function test_forceDisputeTimeout_beforeDeadlineReverts() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 200;
        terms.disputeDuration = 100;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.expectRevert(Clocks.TooEarly.selector);
        escrow.forceDisputeTimeout(id);
    }

    function test_forceDisputeTimeout_withoutATribunal_burns() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        terms.disputeDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        escrow.forceDisputeTimeout(id);
        // No tribunal was signed and nobody gave way: a deadlock, burned (Anexo R, 2026-09-24).
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), PRINCIPAL);
    }

    function test_forceDisputeTimeout_anyone() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        terms.disputeDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.prank(address(0xDEAD));
        escrow.forceDisputeTimeout(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
    }

    function test_terminal_rejectsFurtherStateChange() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        vm.prank(provider);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.markFiat(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.claim(id);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.timeoutFiat(id);
    }
}
