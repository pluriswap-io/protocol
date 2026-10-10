// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit
} from "./Types.sol";
import {Terms} from "./Terms.sol";

library Consent {
    bytes32 internal constant HOLDER_AUTHORIZATION_TYPEHASH = keccak256(
        "HolderAuthorization(DealTerms terms,uint256 nonce,uint256 deadline)DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)"
    );

    bytes32 internal constant PROVIDER_AGREEMENT_TYPEHASH = keccak256(
        "ProviderAgreement(DealTerms terms,uint256 nonce,uint256 deadline)DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)"
    );

    bytes32 internal constant CONTROLLER_ACCEPTANCE_TYPEHASH = keccak256(
        "ControllerAcceptance(DealTerms terms,uint256 nonce,uint256 deadline)DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)"
    );

    function hashHolderAuthorization(HolderAuthorization memory a) public pure returns (bytes32) {
        return keccak256(abi.encode(HOLDER_AUTHORIZATION_TYPEHASH, Terms.hashTerms(a.terms), a.nonce, a.deadline));
    }

    function hashProviderAgreement(ProviderAgreement memory a) public pure returns (bytes32) {
        return keccak256(abi.encode(PROVIDER_AGREEMENT_TYPEHASH, Terms.hashTerms(a.terms), a.nonce, a.deadline));
    }

    function hashControllerAcceptance(ControllerAcceptance memory a) public pure returns (bytes32) {
        return keccak256(abi.encode(CONTROLLER_ACCEPTANCE_TYPEHASH, Terms.hashTerms(a.terms), a.nonce, a.deadline));
    }

    function dealId(
        bytes32 domainSeparator,
        DealTerms memory terms,
        uint256 holderNonce,
        uint256 providerNonce,
        uint256 controllerNonce
    ) public pure returns (bytes32) {
        uint256 encodedControllerNonce = terms.holder == terms.controller ? uint256(0) : controllerNonce;
        return keccak256(
            abi.encode(domainSeparator, Terms.hashTerms(terms), holderNonce, providerNonce, encodedControllerNonce)
        );
    }

    function isValid(address signer, bytes32 digest, bytes memory signature) public view returns (bool) {
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }

    bytes32 internal constant MUTUAL_CANCEL_TYPEHASH =
        keccak256("MutualCancel(bytes32 dealId,uint256 nonce,uint256 deadline)");
    bytes32 internal constant CO_SIGNED_RELEASE_TYPEHASH =
        keccak256("CoSignedRelease(bytes32 dealId,uint256 nonce,uint256 deadline)");
    bytes32 internal constant MUTUAL_SPLIT_TYPEHASH =
        keccak256("MutualSplit(bytes32 dealId,uint16 providerBps,uint256 nonce,uint256 deadline)");

    function hashMutualCancel(MutualCancel memory m) public pure returns (bytes32) {
        return keccak256(abi.encode(MUTUAL_CANCEL_TYPEHASH, m.dealId, m.nonce, m.deadline));
    }

    function hashCoSignedRelease(CoSignedRelease memory m) public pure returns (bytes32) {
        return keccak256(abi.encode(CO_SIGNED_RELEASE_TYPEHASH, m.dealId, m.nonce, m.deadline));
    }

    function hashMutualSplit(MutualSplit memory m) public pure returns (bytes32) {
        return keccak256(abi.encode(MUTUAL_SPLIT_TYPEHASH, m.dealId, m.providerBps, m.nonce, m.deadline));
    }
}
