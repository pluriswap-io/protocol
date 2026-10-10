// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Governed} from "../src/packages/Governed.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateDealTest} from "./PrivateDeal.t.sol";
import {PaymentProofTest} from "./PaymentProof.t.sol";

/// @notice Anexo R, 2026-10-06: the DAO changes the fees of the official reputation for the deals to come. The kernel
///         copies a deal's fees at activation and never asks the module again, so a live deal pays what it signed; a
///         deal signed under the old fees names an id that no longer resolves. Inherits the private-deal suite, so
///         every behaviour of the private reputation is checked again under a governor.
contract PrivateReputationGovernanceTest is PrivateDealTest {
    address internal constant DAO = address(0xDA0);

    function _repGovernor() internal pure override returns (address) {
        return DAO;
    }

    function _next() internal pure returns (PrivateReputation.Fees memory) {
        return PrivateReputation.Fees({activationBps: 0, completionBps: 50, contestBps: 100, contestFloor: 2_000_000});
    }

    function _propose(PrivateReputation.Fees memory f) internal {
        vm.prank(DAO);
        reputation.proposePolicy(f);
    }

    /// The setUp's signatures expire before a 30-day delay does: sign the deal again, under the fees in force.
    function _resign(uint256 nonce) internal {
        ha = _holderAuth(_privateTerms(), nonce);
        pa = _providerAuth(_privateTerms(), nonce);
        dealId = Consent.dealId(escrow.domainSeparator(), _privateTerms(), nonce, nonce, 0);
    }

    function test_repGov_onlyTheGovernor_insideTheBounds() public {
        vm.expectRevert(Governed.NotGovernor.selector);
        reputation.proposePolicy(_next());
        PrivateReputation.Fees[4] memory bad;
        bad[0].activationBps = 101;
        bad[1].completionBps = 101;
        bad[2].contestBps = 301;
        bad[3].contestFloor = 10_000_001;
        for (uint256 i; i < bad.length; i++) {
            vm.prank(DAO);
            vm.expectRevert(Governed.OutOfBounds.selector);
            reputation.proposePolicy(bad[i]);
        }
    }

    function test_repGov_theIdFollowsTheFeesInForce() public {
        bytes32 before = reputation.packageId();
        _propose(_next());
        assertEq(reputation.packageId(), before, "a proposal is not a change");
        assertEq(reputation.pendingFees().completionBps, 50);
        vm.warp(reputation.pendingAt());
        reputation.enactPolicy();
        assertEq(reputation.completionBps(), 50);
        assertEq(reputation.contestFloor(), 2_000_000);
        assertTrue(reputation.packageId() != before);
        (uint256 amount,) = reputation.invoiceCompletion(PRINCIPAL);
        assertEq(amount, PRINCIPAL * 50 / 10_000);
    }

    /// Activated free, finished free: the fees enacted while it was live never reach it, contest included.
    function test_repGov_aLiveDealPaysTheFeesItSigned() public {
        _propose(_next());
        vm.warp(reputation.pendingAt() - 60);
        _resign(1);
        _activate();
        _markFiat(dealId);
        vm.warp(reputation.pendingAt());
        reputation.enactPolicy();

        uint256 before = token.balanceOf(FEE_TO);
        vm.prank(holder);
        escrow.openDisputed(dealId);
        _coSignedRelease(dealId, 11, 12);
        assertEq(uint8(escrow.status(dealId)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(FEE_TO), before, "no contest fee and no completion fee: it signed none");
        assertEq(escrow.pricesOf(dealId).repCompletionBps, 0);
        assertEq(escrow.pricesOf(dealId).repContestFloor, 0);
    }

    /// Resolution comes before any proof is read, so the old id fails first and alone.
    function test_repGov_aDealSignedUnderTheOldFeesDoesNotActivate() public {
        DealTerms memory t = _privateTerms(); // the id of the fees in force today
        _propose(_next());
        vm.warp(reputation.pendingAt());
        reputation.enactPolicy();
        HolderAuthorization memory ha2 = _holderAuth(t, 2);
        ProviderAgreement memory pa2 = _providerAuth(t, 2);
        ControllerAcceptance memory ca;
        bytes memory hs2 = _signHolder(ha2);
        bytes memory ps2 = _signProvider(pa2);
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha2, hs2, pa2, ps2, ca, "", mods);
    }

    function test_repGov_aDealActivatedAfterTheChangePaysTheNewFees() public {
        _propose(_next());
        vm.warp(reputation.pendingAt());
        reputation.enactPolicy();
        _resign(1);
        _activate();
        _markFiat(dealId);
        uint256 before = token.balanceOf(FEE_TO);
        vm.prank(holder);
        escrow.release(dealId);
        assertEq(token.balanceOf(FEE_TO) - before, PRINCIPAL * 50 / 10_000, "the new completion fee");
        assertEq(escrow.pricesOf(dealId).repCompletionBps, 50);
    }
}

/// @notice The DAO changes the price of a payment proof for the deals to come; a live deal pays the one it signed.
///         Inherits the payment-proof suite, so the module is checked again under a governor.
contract PaymentProofGovernanceTest is PaymentProofTest {
    address internal constant DAO = address(0xDA0);
    uint256 internal constant NEW_FEE = 20_000;

    function _governor() internal pure override returns (address) {
        return DAO;
    }

    function _enactFee(uint256 fee) internal {
        vm.prank(DAO);
        module.proposePolicy(fee);
        assertEq(module.pendingVerifyFee(), fee);
        vm.warp(module.pendingAt());
        module.enactPolicy();
    }

    function test_zkGov_onlyTheGovernor_insideTheBound() public {
        vm.expectRevert(Governed.NotGovernor.selector);
        module.proposePolicy(NEW_FEE);
        uint256 tooMuch = module.MAX_VERIFY_FEE() + 1;
        vm.prank(DAO);
        vm.expectRevert(Governed.OutOfBounds.selector);
        module.proposePolicy(tooMuch);
    }

    function test_zkGov_aLiveDealPaysTheFeeItSigned() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes32 before = module.packageId();
        _enactFee(NEW_FEE);
        assertTrue(module.packageId() != before, "a new fee is a new id");
        bytes memory proof = _proof(id, NULLIFIER);
        escrow.verifyProof(id, proof);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(feeRecipient), VERIFY_FEE, "the signed fee, not the new one");
        assertEq(token.balanceOf(provider), PRINCIPAL - VERIFY_FEE);
    }

    function test_zkGov_aDealActivatedAfterTheChangePaysTheNewFee() public {
        _enactFee(NEW_FEE);
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        escrow.verifyProof(id, _proof(id, NULLIFIER));
        assertEq(token.balanceOf(feeRecipient), NEW_FEE);
        assertEq(escrow.pricesOf(id).zkFee, NEW_FEE);
    }

    function test_zkGov_aDealSignedUnderTheOldFeeDoesNotActivate() public {
        DealTerms memory t = _p2pTerms();
        t.fiatCommit = FIAT_COMMIT;
        t.packageIds = new bytes32[](1);
        t.packageIds[0] = module.packageId(); // signed now, under the fee in force
        _enactFee(NEW_FEE);
        PackageMods memory zkMods;
        zkMods.zk = address(module);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", zkMods);
    }
}
