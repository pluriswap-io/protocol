// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract CancelTest is BaseTest {
    function test_cancelByProvider_fromFunded_paysHolder() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_cancelByProvider_revertsAfterMarkFiat() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(provider);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.cancelByProvider(id);
    }

    function test_cancelByProvider_onlyProvider() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.cancelByProvider(id);
    }
}
