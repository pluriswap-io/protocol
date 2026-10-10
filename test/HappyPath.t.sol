// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {HolderAuthorization, ProviderAgreement, ControllerAcceptance} from "../src/libraries/Consent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "./Base.t.sol";

contract HappyPathTest is BaseTest {
    function test_activate_emitsTransitionedAndActivated() public {
        bytes32 id = Consent.dealId(escrow.domainSeparator(), _p2pTerms(), 1, 1, 0);
        // Build and sign the consents BEFORE the expectations: strict expectEmit binds to the
        // very next call, so escrow.activate must be that call.
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        ControllerAcceptance memory ca;
        bytes memory haSig = _signHolder(ha);
        bytes memory paSig = _signProvider(pa);
        // activate pulls the principal before emitting, so the ERC20 Transfer leads the log stream.
        vm.expectEmit(true, false, false, true);
        emit IERC20.Transfer(holder, address(escrow), PRINCIPAL);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Transitioned(id, Status.NONE, Status.FUNDED);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Activated(id, holder, provider, holder, address(token), PRINCIPAL);
        escrow.activate(ha, haSig, pa, paSig, ca, "");
    }

    function test_release_emitsTransitionedAndSettled() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Transitioned(id, Status.FIAT_SENT, Status.RELEASED);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Settled(id, Status.RELEASED, 0, PRINCIPAL);
        vm.prank(holder);
        escrow.release(id);
    }

    function test_markFiat_onlyProvider() public {
        bytes32 id = _activateP2P(1, 1);

        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.markFiat(id);

        vm.prank(provider);
        escrow.markFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.FIAT_SENT));
    }

    function test_release_onlyController_paysProvider() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);

        vm.prank(provider);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);

        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_release_revertsFromFunded() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
    }

    function test_holderCannotRelease_whenDistinctController() public {
        bytes32 id = _activateDistinctController(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);
        vm.prank(controller);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }
}
