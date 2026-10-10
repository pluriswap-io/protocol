// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {Escrow} from "../src/Escrow.sol";
import {PaymentProof} from "../src/packages/PaymentProof.sol";
import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";
import {PaymentVerifierMock} from "../mocks/PaymentVerifierMock.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev The real `PAYMENT_PROOF` module (§E.3.12.1) against the real kernel. The only stand-in is the
///      rail's verifier, whose circuit does not exist yet — the mock checks the one thing every rail
///      adapter must: that the proof names exactly the claim the module built.
contract PaymentProofTest is BaseTest {
    uint256 internal constant VERIFY_FEE = 10_000;
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    bytes32 internal constant NULLIFIER = keccak256("receipt-1");

    PaymentVerifierMock internal verifier;
    PaymentProof internal module;
    address internal feeRecipient = address(0xFEE);

    /// @dev Frozen fee here; `PaymentProofGovernanceTest` runs this whole suite again under a governor.
    function _governor() internal view virtual returns (address) {
        return address(0);
    }

    function setUp() public virtual override {
        super.setUp();
        verifier = new PaymentVerifierMock();
        module = new PaymentProof(address(escrow), verifier, feeRecipient, VERIFY_FEE, _governor());
        token.mint(holder, PRINCIPAL);
    }

    // --- identity ----------------------------------------------------------------------------------------

    function test_packageId_isTheKernelsFormula() public view {
        assertEq(module.packageId(), PackageId.zk(address(module), address(verifier), feeRecipient, VERIFY_FEE));
        (uint256 amount, address to) = module.invoiceVerify();
        assertEq(amount, VERIFY_FEE);
        assertEq(to, feeRecipient);
    }

    function test_packageId_bindsTheModule() public {
        PaymentProof other = new PaymentProof(address(escrow), verifier, feeRecipient, VERIFY_FEE, address(0));
        assertTrue(other.packageId() != module.packageId());
    }

    function test_constructor_rejectsZeroEscrowOrVerifier() public {
        vm.expectRevert(PaymentProof.ZeroAddress.selector);
        new PaymentProof(address(0), verifier, feeRecipient, VERIFY_FEE, address(0));
        vm.expectRevert(PaymentProof.ZeroAddress.selector);
        new PaymentProof(address(escrow), IPaymentVerifier(address(0)), feeRecipient, VERIFY_FEE, address(0));
    }

    // --- the path -----------------------------------------------------------------------------------------

    function test_proofOfTheSignedPayment_releases() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        vm.recordLogs();
        escrow.verifyProof(id, _proof(id, NULLIFIER));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL - VERIFY_FEE);
        assertEq(token.balanceOf(feeRecipient), VERIFY_FEE);
        assertTrue(module.used(NULLIFIER));
        assertTrue(_emittedPaymentProven(id, NULLIFIER), "PaymentProven");
    }

    /// Only the kernel may spend a nullifier: anyone calling the module directly would burn a real
    /// payment's nullifier without releasing anything, and the Provider could never use it again.
    function test_onlyTheEscrow() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes memory proof = _proof(id, NULLIFIER);
        vm.expectRevert(PaymentProof.Unauthorized.selector);
        module.verifyProof(id, proof);
        assertFalse(module.used(NULLIFIER));
    }

    // --- the claim is the kernel's, never the caller's ----------------------------------------------------

    function test_proofOfAnotherDeal_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes memory proof =
            verifier.proofFor(_claim(keccak256("another deal"), FIAT_COMMIT, _activatedAt(id)), NULLIFIER);
        vm.expectRevert(PaymentProof.InvalidProof.selector);
        escrow.verifyProof(id, proof);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertFalse(module.used(NULLIFIER));
    }

    /// The whole reason the terms sign the fiat leg: a real payment, but not the one agreed — a smaller
    /// amount, another account — opens another commitment, and does not release.
    function test_proofOfAnotherPayment_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes memory proof = verifier.proofFor(_claim(id, keccak256("a cheaper payment"), _activatedAt(id)), NULLIFIER);
        vm.expectRevert(PaymentProof.InvalidProof.selector);
        escrow.verifyProof(id, proof);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    /// `notBefore` is the kernel's activation clock. A proof built against an earlier bound would let a
    /// payment made before the escrow existed — an old transfer between the same two people — settle it.
    function test_proofAgainstAnEarlierBound_isRejected() public {
        vm.warp(1_000_000);
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes memory proof = verifier.proofFor(_claim(id, FIAT_COMMIT, _activatedAt(id) - 1), NULLIFIER);
        vm.expectRevert(PaymentProof.InvalidProof.selector);
        escrow.verifyProof(id, proof);
    }

    /// The Holder in the claim is the one in the signed terms: it is the only party whose approval can
    /// extend which keys count for this deal (§E.3.12.1), so the caller must not be able to name another.
    function test_proofNamingAnotherHolder_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        bytes memory proof = verifier.proofFor(_claimFor(id, FIAT_COMMIT, _activatedAt(id), address(0xBAD)), NULLIFIER);
        vm.expectRevert(PaymentProof.InvalidProof.selector);
        escrow.verifyProof(id, proof);
    }

    function test_verifierSaysNo_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        verifier.setAnswer(false);
        bytes memory proof = _proof(id, NULLIFIER);
        vm.expectRevert(PaymentProof.InvalidProof.selector);
        escrow.verifyProof(id, proof);
        assertFalse(module.used(NULLIFIER));
    }

    // --- one payment, one deal ----------------------------------------------------------------------------

    function test_onePaymentSettlesOneDeal() public {
        token.mint(holder, PRINCIPAL);
        bytes32 a = _activateZk(FIAT_COMMIT, 1);
        bytes32 b = _activateZk(FIAT_COMMIT, 2);
        escrow.verifyProof(a, _proof(a, NULLIFIER));
        bytes memory replay = _proof(b, NULLIFIER);
        vm.expectRevert(PaymentProof.NullifierUsed.selector);
        escrow.verifyProof(b, replay);
        assertEq(uint8(escrow.status(b)), uint8(Status.FUNDED));
    }

    // --- a late proof (Anexo R, 2026-09-24) -------------------------------------------------------------

    /// `fiatDeadline` does not close a ZK deal; `timeoutFiat` does. Until somebody calls it, a proof of the
    /// signed payment still releases — the Provider paid, the evidence is authentic, and the Holder has
    /// lost nothing by waiting. After the deadline it is a race, and the race is the catalog's (§E.3.10).
    function test_lateProof_releasesWhileStillFunded() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        vm.warp(block.timestamp + _p2pTerms().fiatDuration + 1 days);
        escrow.verifyProof(id, _proof(id, NULLIFIER));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL - VERIFY_FEE);
    }

    /// Once the deal is cancelled the principal is home, and no proof reopens it.
    function test_proofAfterTimeoutCancel_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        vm.warp(block.timestamp + _p2pTerms().fiatDuration + 1);
        escrow.timeoutFiat(id);
        bytes memory proof = _proof(id, NULLIFIER);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.verifyProof(id, proof);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), 2 * PRINCIPAL);
        assertFalse(module.used(NULLIFIER));
    }

    function test_proofAfterProviderCancel_isRejected() public {
        bytes32 id = _activateZk(FIAT_COMMIT, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        bytes memory proof = _proof(id, NULLIFIER);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.verifyProof(id, proof);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
    }

    // --- the commitment must be provable ------------------------------------------------------------------

    /// A commitment at or above the BN254 modulus is not a Poseidon output: no circuit can take it as a
    /// public input, so no proof will ever open it. The kernel cannot know that (the field is the rail's
    /// business), so the module says it — in words, rather than as a proof that silently never verifies.
    function test_commitmentOutsideTheField_isNamed() public {
        bytes32 id = _activateZk(bytes32(BN254_P), 1);
        bytes memory proof = _proof(id, NULLIFIER);
        vm.expectRevert(PaymentProof.FiatCommitNotInField.selector);
        escrow.verifyProof(id, proof);
    }

    // --- helpers ------------------------------------------------------------------------------------------

    function _activateZk(bytes32 fiatCommit, uint256 nonce) internal returns (bytes32) {
        DealTerms memory t = _p2pTerms();
        t.fiatCommit = fiatCommit;
        t.packageIds = new bytes32[](1);
        t.packageIds[0] = module.packageId();
        PackageMods memory mods;
        mods.zk = address(module);
        HolderAuthorization memory ha = _holderAuth(t, nonce);
        ProviderAgreement memory pa = _providerAuth(t, nonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }

    function _activatedAt(bytes32 id) internal view returns (uint64) {
        return uint64(escrow.clocks(id).activatedAt);
    }

    function _claim(bytes32 dealId, bytes32 fiatCommit, uint64 notBefore)
        internal
        view
        returns (IPaymentVerifier.PaymentClaim memory)
    {
        return _claimFor(dealId, fiatCommit, notBefore, holder);
    }

    function _claimFor(bytes32 dealId, bytes32 fiatCommit, uint64 notBefore, address holder_)
        internal
        pure
        returns (IPaymentVerifier.PaymentClaim memory)
    {
        return IPaymentVerifier.PaymentClaim({
            dealId: dealId, fiatCommit: fiatCommit, notBefore: notBefore, holder: holder_
        });
    }

    /// A proof of exactly the claim the module will build for this deal.
    function _proof(bytes32 id, bytes32 nullifier) internal view returns (bytes memory) {
        return verifier.proofFor(_claim(id, escrow.terms(id).fiatCommit, _activatedAt(id)), nullifier);
    }

    function _emittedPaymentProven(bytes32 id, bytes32 nullifier) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(module) && logs[i].topics[0] == PaymentProof.PaymentProven.selector
                    && logs[i].topics[1] == id && logs[i].topics[2] == nullifier
            ) return true;
        }
        return false;
    }
}
