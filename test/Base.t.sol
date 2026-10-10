// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";

contract BaseTest is Test {
    uint256 internal constant PRINCIPAL = 1_000_000;
    /// Stand-in for `Poseidon(TAG_FIAT, rail, currency, amount, payee, salt)`. The kernel treats it as
    /// opaque, but `PaymentProof` rejects anything a circuit could not take, so it is a field element
    /// (shifted under 2^248 < p), as every real Poseidon output is.
    bytes32 internal constant FIAT_COMMIT = bytes32(uint256(keccak256("fiat leg")) >> 8);

    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    uint256 internal controllerPk = 0xC0;

    Escrow internal escrow;
    TestToken internal token;
    address internal holder;
    address internal provider;
    address internal controller;

    function setUp() public virtual {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        escrow = new Escrow(address(0), 0, 0);
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
    }

    function _p2pTerms() internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = PRINCIPAL;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.fiatCommit = FIAT_COMMIT;
        t.packageIds = new bytes32[](0);
    }

    /// All-zero package slots, for Core-only `Pool.authorize`. `Packages.resolve` accepts it against empty
    /// `packageIds`, and rejects it against any signed id -- which is the point of passing mods at all.
    function _noMods() internal pure returns (PackageMods memory m) {}

    /// PASSPORT + REPUTATION slots only, for the pool authorization tests that bind a reputation module.
    function _mods(address passport_, address reputation_) internal pure returns (PackageMods memory m) {
        m.passport = passport_;
        m.reputation = reputation_;
    }

    /// A `PaymentVerifierMock` blob naming exactly the claim `PaymentProof` builds for this deal: its id,
    /// its signed fiat leg, its activation clock.
    function _paymentProof(bytes32 id, bytes32 nullifier) internal view returns (bytes memory) {
        return abi.encode(
            IPaymentVerifier.PaymentClaim({
                dealId: id,
                fiatCommit: escrow.terms(id).fiatCommit,
                notBefore: uint64(escrow.clocks(id).activatedAt),
                holder: escrow.terms(id).holder
            }),
            nullifier
        );
    }

    function _typed(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
    }

    function _sign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _holderAuth(DealTerms memory terms, uint256 nonce) internal view returns (HolderAuthorization memory a) {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _providerAuth(DealTerms memory terms, uint256 nonce) internal view returns (ProviderAgreement memory a) {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _controllerAuth(DealTerms memory terms, uint256 nonce)
        internal
        view
        returns (ControllerAcceptance memory a)
    {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _signHolder(HolderAuthorization memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashHolderAuthorization(a)), holderPk);
    }

    function _signProvider(ProviderAgreement memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashProviderAgreement(a)), providerPk);
    }

    function _signController(ControllerAcceptance memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashControllerAcceptance(a)), controllerPk);
    }

    function _poolTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.controller = controller;
    }

    function _activateP2P(uint256 holderNonce, uint256 providerNonce) internal returns (bytes32) {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), holderNonce);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), providerNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");
    }

    function _activateP2PWith(DealTerms memory terms, uint256 holderNonce, uint256 providerNonce)
        internal
        returns (bytes32)
    {
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");
    }

    function _activateDistinctController(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _poolTerms();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, _signController(ca));
    }

    function _markFiat(bytes32 id) internal {
        vm.prank(provider);
        escrow.markFiat(id);
    }

    function _mutualCancel(bytes32 id, uint256 providerNonce, uint256 controllerNonce) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualCancel memory p = MutualCancel({dealId: id, nonce: providerNonce, deadline: deadline});
        MutualCancel memory c = MutualCancel({dealId: id, nonce: controllerNonce, deadline: deadline});
        escrow.mutualCancel(
            p,
            _sign(_typed(Consent.hashMutualCancel(p)), providerPk),
            c,
            _sign(_typed(Consent.hashMutualCancel(c)), holderPk)
        );
    }

    function _coSignedRelease(bytes32 id, uint256 providerNonce, uint256 controllerNonce) internal {
        uint256 deadline = block.timestamp + 1 days;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: providerNonce, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: controllerNonce, deadline: deadline});
        escrow.coSignedRelease(
            p,
            _sign(_typed(Consent.hashCoSignedRelease(p)), providerPk),
            c,
            _sign(_typed(Consent.hashCoSignedRelease(c)), holderPk)
        );
    }

    function _mutualSplit(bytes32 id, uint16 bps, uint256 providerNonce, uint256 controllerNonce) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: providerNonce, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: controllerNonce, deadline: deadline});
        escrow.mutualSplit(
            p,
            _sign(_typed(Consent.hashMutualSplit(p)), providerPk),
            c,
            _sign(_typed(Consent.hashMutualSplit(c)), holderPk)
        );
    }

    /// @dev The kernel takes the signed ids in ascending order.
    function _sortIds(bytes32[] memory ids) internal pure returns (bytes32[] memory) {
        for (uint256 i; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                if (ids[j] < ids[i]) (ids[i], ids[j]) = (ids[j], ids[i]);
            }
        }
        return ids;
    }

    function _openDisputed(bytes32 id) internal virtual {
        vm.prank(holder);
        escrow.openDisputed(id);
    }
}
