// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {Mock1271} from "../mocks/Mock1271.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev Holder-contrato + Controller distinct, Core-only (no packageIds). Not a pool service.
contract PoolHolderTest is BaseTest {
    Mock1271 internal pool;

    function setUp() public override {
        super.setUp();
        pool = new Mock1271();
        pool.setOk(true);
        token.mint(address(pool), PRINCIPAL);
        vm.prank(address(pool));
        token.approve(address(escrow), type(uint256).max);
    }

    function test_pool1271_activateSameTypedData() public {
        DealTerms memory terms = _holderContractTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);

        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));

        bytes32 expected = Consent.dealId(escrow.domainSeparator(), terms, ha.nonce, pa.nonce, ca.nonce);
        assertEq(id, expected);
        assertEq(terms.packageIds.length, 0);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(token.balanceOf(controller), 0);
        assertTrue(escrow.used(address(pool), ha.nonce));
        assertTrue(escrow.used(provider, pa.nonce));
        assertTrue(escrow.used(controller, ca.nonce));
        assertFalse(escrow.used(holder, ha.nonce));
    }

    function test_pool1271_holderCannotRelease_controllerPaysProvider() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);

        vm.prank(address(pool));
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);

        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);

        vm.prank(controller);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(controller), 0);
    }

    function test_pool1271_cancelPaysHolderNotController() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
        assertEq(token.balanceOf(controller), 0);
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_pool1271_rejectDoesNotConsumeNonce() public {
        pool.setOk(false);
        DealTerms memory terms = _holderContractTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);

        bytes memory providerSig = _signProvider(pa);
        bytes memory controllerSig = _signController(ca);
        vm.expectRevert(Escrow.InvalidHolderSignature.selector);
        escrow.activate(ha, "", pa, providerSig, ca, controllerSig);

        assertFalse(escrow.used(address(pool), ha.nonce));
        assertFalse(escrow.used(provider, pa.nonce));
        assertFalse(escrow.used(controller, ca.nonce));
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
    }

    function test_pool1271_twoConcurrentDealsDifferentNonces() public {
        token.mint(address(pool), PRINCIPAL);
        bytes32 id1 = _activatePool(1, 1, 1);
        bytes32 id2 = _activatePool(2, 2, 2);
        assertTrue(id1 != id2);
        assertEq(uint8(escrow.status(id1)), uint8(Status.FUNDED));
        assertEq(uint8(escrow.status(id2)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL * 2);
    }

    function _holderContractTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
    }

    function _activatePool(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _holderContractTerms();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }
}
