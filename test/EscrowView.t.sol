// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, PackageMods, DealClocks} from "../src/libraries/Types.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {BaseTest} from "./Base.t.sol";

contract EscrowViewTest is BaseTest {
    function test_unknownDeal_readsEmpty() public view {
        IEscrow view_ = IEscrow(address(escrow));
        bytes32 id = bytes32(uint256(1));
        DealTerms memory t = view_.terms(id);
        DealClocks memory c = view_.clocks(id);
        (bytes32 h, bytes32 p) = view_.subjects(id);
        PackageMods memory m = view_.modules(id);
        assertEq(uint8(view_.status(id)), uint8(Status.NONE));
        assertEq(t.principal, 0);
        assertEq(t.fiatCommit, bytes32(0));
        assertEq(t.packageIds.length, 0);
        assertEq(c.activatedAt, 0);
        assertEq(h, bytes32(0));
        assertEq(p, bytes32(0));
        assertEq(m.passport, address(0));
        assertEq(view_.kinds(id), 0);
    }

    function test_activate_exposesTermsClocksKinds() public {
        uint256 t0 = block.timestamp;
        bytes32 id = _activateP2P(1, 1);
        IEscrow view_ = IEscrow(address(escrow));
        DealTerms memory t = view_.terms(id);
        DealClocks memory c = view_.clocks(id);
        assertEq(t.holder, holder);
        assertEq(t.provider, provider);
        assertEq(t.principal, PRINCIPAL);
        assertEq(t.fiatCommit, FIAT_COMMIT);
        assertEq(t.packageIds.length, 0);
        assertEq(c.activatedAt, t0);
        assertEq(c.fiatSentAt, 0);
        assertEq(view_.kinds(id), 0);
        assertEq(view_.modules(id).reputation, address(0));
    }

    function test_activate_setsDealOf() public {
        bytes32 id = _activateP2P(1, 1);
        IEscrow view_ = IEscrow(address(escrow));
        assertEq(view_.dealOf(holder, 1), id);
        assertEq(view_.dealOf(provider, 1), id);
        assertEq(view_.dealOf(holder, 2), bytes32(0));
        assertEq(view_.dealOf(controller, 1), bytes32(0));
    }

    function test_activate_setsDealOfControllerWhenDistinct() public {
        bytes32 id = _activateDistinctController(1, 1, 1);
        IEscrow view_ = IEscrow(address(escrow));
        assertEq(view_.dealOf(holder, 1), id);
        assertEq(view_.dealOf(provider, 1), id);
        assertEq(view_.dealOf(controller, 1), id);
    }

    function test_markFiat_setsFiatSentClock() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        DealClocks memory c = IEscrow(address(escrow)).clocks(id);
        assertEq(c.fiatSentAt, block.timestamp);
        assertTrue(c.fiatSentAt >= c.activatedAt);
    }
}
