// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status} from "../src/libraries/Types.sol";
import {BaseTest} from "./Base.t.sol";

contract SettlementOfTest is BaseTest {
    function test_settlementOf_unknownIsZero() public view {
        (Status st, uint256 h, uint256 p) = escrow.settlementOf(bytes32(uint256(1)));
        assertEq(uint8(st), uint8(Status.NONE));
        assertEq(h, 0);
        assertEq(p, 0);
    }

    function test_settlementOf_release() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        (Status st, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RELEASED));
        assertEq(h, 0);
        assertEq(p, PRINCIPAL);
    }

    function test_settlementOf_cancelReturnsPrincipal() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        (Status st, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CANCELLED));
        assertEq(h, PRINCIPAL);
        assertEq(p, 0);
    }

    function test_settlementOf_deadlockPaysNobody() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        (Status st, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE));
        assertEq(h, 0);
        assertEq(p, 0, "the principal was burned, not settled");
    }
}
