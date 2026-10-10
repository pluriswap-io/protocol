// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";

/// @title A deal can be followed by its id
/// @notice Evaluation of 2026-09-28: `Activated`, `Transitioned` and `Settled` carried `dealId` in their data,
///         so an indexer or a frontend could not ask a node for one deal's history — it had to download every
///         event of the escrow and filter. `dealId` is the first indexed topic of every per-deal event.
contract EventTopicsTest is BaseTest {
    bytes32 internal constant ACTIVATED = keccak256("Activated(bytes32,address,address,address,address,uint256)");
    bytes32 internal constant TRANSITIONED = keccak256("Transitioned(bytes32,uint8,uint8)");
    bytes32 internal constant SETTLED = keccak256("Settled(bytes32,uint8,uint256,uint256)");

    function test_activated_isIndexedByDealId() public {
        vm.recordLogs();
        bytes32 id = _activateP2P(1, 2);
        _assertTopic(vm.getRecordedLogs(), ACTIVATED, id);
    }

    function test_transitionedAndSettled_areIndexedByDealId() public {
        bytes32 id = _activateP2P(3, 4);
        vm.recordLogs();
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertTopic(logs, TRANSITIONED, id);
        _assertTopic(logs, SETTLED, id);
    }

    function _assertTopic(Vm.Log[] memory logs, bytes32 sig, bytes32 id) internal view {
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(escrow) || logs[i].topics[0] != sig) continue;
            seen = true;
            assertGe(logs[i].topics.length, 2, "dealId is a topic");
            assertEq(logs[i].topics[1], id, "and it is the first one");
        }
        assertTrue(seen, "the event was emitted");
    }
}
