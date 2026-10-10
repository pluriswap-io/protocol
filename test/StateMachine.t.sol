// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, MutualCancel} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev One test per Core catalog case (PROTOCOLO.md §E.3.9). Packages (ZK, arb) are out of scope.
contract StateMachineTest is BaseTest {
    uint256 internal nonce = 1;

    function _nextActivate() internal returns (bytes32) {
        uint256 n = nonce++;
        return _activateP2P(n, n);
    }

    function _nextActivateWith(DealTerms memory terms) internal returns (bytes32) {
        uint256 n = nonce++;
        return _activateP2PWith(terms, n, n);
    }

    function _fiatSent() internal returns (bytes32 id) {
        id = _nextActivate();
        _markFiat(id);
    }

    function _disputed() internal returns (bytes32 id) {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        id = _nextActivateWith(terms);
        _markFiat(id);
        _openDisputed(id);
    }

    function test_CASE_CORE_01_activateP2P() public {
        bytes32 id = _activateP2P(1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
    }

    function test_CASE_CORE_01_activateDistinctController() public {
        bytes32 id = _activateDistinctController(1, 1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_CASE_CORE_02_markFiat() public {
        bytes32 id = _activateP2P(1, 1);
        _markFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.FIAT_SENT));
    }

    function test_CASE_CORE_03_cancelByProvider() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_CASE_CORE_04_timeoutFiat() public {
        DealTerms memory terms = _p2pTerms();
        terms.fiatDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(address(0xDEAD));
        escrow.timeoutFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_CASE_CORE_05_mutualCancelFromFunded() public {
        bytes32 id = _activateP2P(1, 1);
        _mutualCancel(id, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_CASE_CORE_06_controllerRelease() public {
        bytes32 id = _fiatSent();
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_CASE_CORE_07_claim() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        _markFiat(id);
        vm.prank(address(0xDEAD));
        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_CASE_CORE_08_mutualCancelFromFiatSent() public {
        bytes32 id = _fiatSent();
        _mutualCancel(id, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_CASE_CORE_09_mutualSplitFromFiatSent() public {
        bytes32 id = _fiatSent();
        _mutualSplit(id, 2500, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_SPLIT));
        assertEq(token.balanceOf(provider), PRINCIPAL * 2500 / 10_000);
        assertEq(token.balanceOf(holder), PRINCIPAL * 7500 / 10_000);
    }

    function test_CASE_CORE_10_coSignedReleaseFromFiatSent() public {
        bytes32 id = _fiatSent();
        _coSignedRelease(id, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_CASE_CORE_11_openDisputed() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        _markFiat(id);
        _openDisputed(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
    }

    function test_CASE_CORE_12_mutualCancelFromDisputed() public {
        bytes32 id = _disputed();
        _mutualCancel(id, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_CASE_CORE_13_coSignedReleaseFromDisputed() public {
        bytes32 id = _disputed();
        _coSignedRelease(id, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_CASE_CORE_14_mutualSplitFromDisputed_rejects() public {
        bytes32 id = _disputed();
        vm.expectRevert(Escrow.SplitAfterDispute.selector);
        this.splitExternally(id, 4000, 10, 11);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
    }

    /// External hop so `vm.expectRevert` binds to the split and not to the helper's signature reads.
    function splitExternally(bytes32 id, uint16 bps, uint256 pn, uint256 cn) external {
        _mutualSplit(id, bps, pn, cn);
    }

    function test_CASE_CORE_15_forceDisputeTimeout() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        terms.disputeDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.prank(address(0xDEAD));
        escrow.forceDisputeTimeout(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), PRINCIPAL, "burned");
    }

    function test_CASE_CORE_16_unilateralRejectedWhileDisputed() public {
        bytes32 id = _disputed();
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
    }

    function test_CASE_CORE_17_everyTerminalRejects() public {
        token.mint(holder, PRINCIPAL * 3);

        bytes32 released = _fiatSent();
        vm.prank(holder);
        escrow.release(released);
        _assertTerminal(released);

        bytes32 cancelled = _nextActivate();
        vm.prank(provider);
        escrow.cancelByProvider(cancelled);
        _assertTerminal(cancelled);

        bytes32 split = _fiatSent();
        _mutualSplit(split, 5000, 20, 21);
        _assertTerminal(split);

        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        terms.disputeDuration = 0;
        bytes32 stalemate = _nextActivateWith(terms);
        _markFiat(stalemate);
        _openDisputed(stalemate);
        escrow.forceDisputeTimeout(stalemate);
        _assertTerminal(stalemate);
    }

    function _assertTerminal(bytes32 id) internal {
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
        vm.prank(provider);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.cancelByProvider(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.openDisputed(id);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.forceDisputeTimeout(id);

        uint256 deadline = block.timestamp + 1 days;
        MutualCancel memory p = MutualCancel({dealId: id, nonce: nonce++, deadline: deadline});
        MutualCancel memory c = MutualCancel({dealId: id, nonce: nonce++, deadline: deadline});
        bytes memory pSig = _sign(_typed(Consent.hashMutualCancel(p)), providerPk);
        bytes memory cSig = _sign(_typed(Consent.hashMutualCancel(c)), holderPk);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.mutualCancel(p, pSig, c, cSig);
    }
}
