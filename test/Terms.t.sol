// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DealTerms} from "../src/libraries/Types.sol";
import {Terms} from "../src/libraries/Terms.sol";

contract TermsTest is Test {
    address internal holder = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal token = address(0x5555);

    function _validTerms() internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = token;
        t.principal = 1_000_000;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.arbitrationDuration = 0;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8);
        t.packageIds = new bytes32[](0);
    }

    function test_hashTerms_stable() public view {
        DealTerms memory a = _validTerms();
        DealTerms memory b = _validTerms();
        bytes32 ha = Terms.hashTerms(a);
        bytes32 hb = Terms.hashTerms(b);
        assertEq(ha, hb);
        assertTrue(ha != bytes32(0), "hash must be non-zero");
        a.principal = 2_000_000;
        assertTrue(Terms.hashTerms(a) != hb, "principal must enter the hash");
    }

    function test_hashTerms_revertsIfPackageIdsUnsorted() public {
        DealTerms memory t = _validTerms();
        t.packageIds = new bytes32[](2);
        t.packageIds[0] = bytes32(uint256(2));
        t.packageIds[1] = bytes32(uint256(1));
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfDuplicatePackageId() public {
        DealTerms memory t = _validTerms();
        t.packageIds = new bytes32[](2);
        t.packageIds[0] = bytes32(uint256(1));
        t.packageIds[1] = bytes32(uint256(1));
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfHolderEqualsProvider() public {
        DealTerms memory t = _validTerms();
        t.provider = t.holder;
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfPrincipalZero() public {
        DealTerms memory t = _validTerms();
        t.principal = 0;
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    /// The fiat leg is part of the agreement: the kernel never reads it, but two parties who committed
    /// to different payments have not agreed on the same deal, and cannot produce the same hash.
    function test_hashTerms_bindsFiatCommit() public view {
        DealTerms memory a = _validTerms();
        DealTerms memory b = _validTerms();
        b.fiatCommit = keccak256("another fiat leg");
        assertTrue(Terms.hashTerms(a) != Terms.hashTerms(b), "fiatCommit must enter the hash");
    }

    /// A Core deal may leave the fiat leg undeclared: the kernel does not interpret it, and only
    /// `PAYMENT_PROOF` consumes it (rejected at activation, not at hashing — see Packages.t.sol).
    function test_hashTerms_acceptsZeroFiatCommit() public view {
        DealTerms memory t = _validTerms();
        t.fiatCommit = bytes32(0);
        assertTrue(Terms.hashTerms(t) != bytes32(0));
    }

    /// The typehash is what a wallet renders. Pinned as a literal so a reorder is a failing test, not a
    /// silent change of every signature in flight.
    function test_typehash_pinned() public pure {
        assertEq(
            Terms.DEAL_TERMS_TYPEHASH,
            keccak256(
                "DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)"
            )
        );
    }
}
