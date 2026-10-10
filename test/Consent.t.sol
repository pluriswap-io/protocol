// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {DealTerms, HolderAuthorization, ProviderAgreement, ControllerAcceptance} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Mock1271} from "../mocks/Mock1271.sol";

contract ConsentHarness is EIP712 {
    constructor() EIP712("PluriSwap", "1") {}

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function holderDigest(HolderAuthorization memory a) external view returns (bytes32) {
        return _hashTypedDataV4(Consent.hashHolderAuthorization(a));
    }

    function providerDigest(ProviderAgreement memory a) external view returns (bytes32) {
        return _hashTypedDataV4(Consent.hashProviderAgreement(a));
    }

    function controllerDigest(ControllerAcceptance memory a) external view returns (bytes32) {
        return _hashTypedDataV4(Consent.hashControllerAcceptance(a));
    }
}

contract ConsentTest is Test {
    ConsentHarness internal harness;
    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    uint256 internal controllerPk = 0xC0;
    address internal holder;
    address internal provider;
    address internal controller;

    function setUp() public {
        harness = new ConsentHarness();
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
    }

    function _terms(address h, address c, address p) internal pure returns (DealTerms memory t) {
        t.holder = h;
        t.controller = c;
        t.provider = p;
        t.token = address(0x5555);
        t.principal = 1_000_000;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8);
        t.packageIds = new bytes32[](0);
    }

    function _sign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_holderAuthorization_eoaRecovers() public view {
        HolderAuthorization memory a;
        a.terms = _terms(holder, holder, provider);
        a.nonce = 1;
        a.deadline = block.timestamp + 1 days;
        bytes32 digest = harness.holderDigest(a);
        bytes memory sig = _sign(digest, holderPk);
        assertTrue(SignatureChecker.isValidSignatureNow(holder, digest, sig));
        a.terms.principal = 2_000_000;
        bytes32 digest2 = harness.holderDigest(a);
        assertTrue(digest != digest2, "terms must enter the digest");
        assertFalse(SignatureChecker.isValidSignatureNow(holder, digest2, sig));
    }

    function test_providerAgreement_eoaRecovers() public view {
        ProviderAgreement memory a;
        a.terms = _terms(holder, holder, provider);
        a.nonce = 7;
        a.deadline = block.timestamp + 1 days;
        bytes32 digest = harness.providerDigest(a);
        bytes memory sig = _sign(digest, providerPk);
        assertTrue(SignatureChecker.isValidSignatureNow(provider, digest, sig));
        assertFalse(SignatureChecker.isValidSignatureNow(holder, digest, sig));
    }

    function test_controllerAcceptance_eoaRecovers() public view {
        ControllerAcceptance memory a;
        a.terms = _terms(holder, controller, provider);
        a.nonce = 3;
        a.deadline = block.timestamp + 1 days;
        bytes32 digest = harness.controllerDigest(a);
        bytes memory sig = _sign(digest, controllerPk);
        assertTrue(SignatureChecker.isValidSignatureNow(controller, digest, sig));
        assertFalse(SignatureChecker.isValidSignatureNow(holder, digest, sig));
    }

    function test_holderAuthorization_1271MagicValue() public {
        Mock1271 wallet = new Mock1271();
        wallet.setOk(true);
        HolderAuthorization memory a;
        a.terms = _terms(address(wallet), address(wallet), provider);
        a.nonce = 1;
        a.deadline = block.timestamp + 1 days;
        bytes32 digest = harness.holderDigest(a);
        assertTrue(Consent.isValid(address(wallet), digest, hex""));
    }

    function test_holderAuthorization_1271Rejects() public {
        Mock1271 wallet = new Mock1271();
        wallet.setOk(false);
        HolderAuthorization memory a;
        a.terms = _terms(address(wallet), address(wallet), provider);
        a.nonce = 1;
        a.deadline = block.timestamp + 1 days;
        bytes32 digest = harness.holderDigest(a);
        assertFalse(Consent.isValid(address(wallet), digest, hex""));
    }

    function test_differentNonces_differentDigests() public view {
        HolderAuthorization memory a;
        a.terms = _terms(holder, holder, provider);
        a.nonce = 1;
        a.deadline = block.timestamp + 1 days;
        bytes32 d1 = harness.holderDigest(a);
        a.nonce = 2;
        bytes32 d2 = harness.holderDigest(a);
        assertTrue(d1 != d2);
    }

    function test_dealId_deterministic() public view {
        DealTerms memory t = _terms(holder, holder, provider);
        bytes32 domain = harness.domainSeparator();
        bytes32 a = Consent.dealId(domain, t, 1, 2, 99);
        bytes32 b = Consent.dealId(domain, t, 1, 2, 99);
        assertEq(a, b);
        // holder == controller → controller nonce encoded as 0, so 99 vs 0 must match
        assertEq(a, Consent.dealId(domain, t, 1, 2, 0));
        assertTrue(a != Consent.dealId(domain, t, 1, 3, 0));
        DealTerms memory distinct = _terms(holder, controller, provider);
        assertTrue(Consent.dealId(domain, distinct, 1, 2, 5) != Consent.dealId(domain, distinct, 1, 2, 6));
    }

    /// A deal is one agreement on both legs: same crypto terms, different fiat commitment, different id.
    function test_dealId_bindsFiatCommit() public view {
        DealTerms memory a = _terms(holder, holder, provider);
        DealTerms memory b = _terms(holder, holder, provider);
        b.fiatCommit = keccak256("another fiat leg");
        bytes32 domain = harness.domainSeparator();
        assertTrue(Consent.dealId(domain, a, 1, 2, 0) != Consent.dealId(domain, b, 1, 2, 0));
    }

    function test_activationTypehashes_carryFiatCommit() public pure {
        string memory terms =
            "DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)";
        assertEq(
            Consent.HOLDER_AUTHORIZATION_TYPEHASH,
            keccak256(abi.encodePacked("HolderAuthorization(DealTerms terms,uint256 nonce,uint256 deadline)", terms))
        );
        assertEq(
            Consent.PROVIDER_AGREEMENT_TYPEHASH,
            keccak256(abi.encodePacked("ProviderAgreement(DealTerms terms,uint256 nonce,uint256 deadline)", terms))
        );
        assertEq(
            Consent.CONTROLLER_ACCEPTANCE_TYPEHASH,
            keccak256(abi.encodePacked("ControllerAcceptance(DealTerms terms,uint256 nonce,uint256 deadline)", terms))
        );
    }
}
