// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {IAccountVerifier} from "../src/packages/interfaces/IAccountVerifier.sol";
import {IClaimVerifier} from "../src/packages/interfaces/IClaimVerifier.sol";
import {IHumanityVerifier} from "../src/packages/interfaces/IHumanityVerifier.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title Private register tests (F1, PROTOCOLO.md §E.3.15.3 and §E.3.15.11)
/// @dev One human (one hn) = one account. The bundle order passport -> reputation is enforced
///      on-chain: reputation only trusts an hn the passport has already burned in this tx.
///      Verifier mocks decode the proof as a bool: a passing mock is not privacy.
contract PrivateRegisterTest is Test {
    BundleVerifierMock internal bundle;
    bytes32 internal constant HN_A = keccak256("human-a");
    bytes32 internal constant HN_B = keccak256("human-b");
    bytes32 internal constant LEAF_A = bytes32(uint256(0xA));
    bytes32 internal constant LEAF_B = bytes32(uint256(0xB));
    address internal constant FEE_TO = address(0xFEE);

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    ClaimVerifierMock internal claimProof;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;

    function setUp() public {
        bundle = new BundleVerifierMock();
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        claimProof = new ClaimVerifierMock();
        // The accounts tree is wired into the passport before its owner exists, so
        // PrivateReputation's CREATE address is predicted (tree, passport, then reputation
        // itself consume the next three nonces).
        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        passport = new PrivatePassport(tree, humanity, bundle, address(0));
        reputation = new PrivateReputation(
            passport, tree, account, bundle, claimProof, FEE_TO, 0, 0, 0, 0, address(this), address(0), 0, address(0)
        );
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    // ---------------------------------------------------------------- PrivatePassport.register

    function test_humanity_burnsHn() public {
        vm.expectEmit(true, true, true, true, address(passport));
        emit PrivatePassport.HumanityRegistered(HN_A);
        passport.register(ok(true), HN_A);
        assertTrue(passport.humanitySpent(HN_A));
    }

    function test_humanity_replayReverts() public {
        passport.register(ok(true), HN_A);
        vm.expectRevert(PrivatePassport.HumanAlreadySpent.selector);
        passport.register(ok(true), HN_A);
        assertTrue(passport.humanitySpent(HN_A));
    }

    function test_humanity_badProofMarksNothing() public {
        vm.expectRevert(PrivatePassport.HumanityNotVerified.selector);
        passport.register(ok(false), HN_A);
        assertFalse(passport.humanitySpent(HN_A));
    }

    function test_humanity_zeroConstructorArgs() public {
        vm.expectRevert(PrivatePassport.ZeroAddress.selector);
        new PrivatePassport(PoseidonTree(address(0)), humanity, bundle, address(0));
        vm.expectRevert(PrivatePassport.ZeroAddress.selector);
        new PrivatePassport(tree, IHumanityVerifier(address(0)), bundle, address(0));
        vm.expectRevert(PrivatePassport.ZeroAddress.selector);
        new PrivatePassport(tree, humanity, IBundleVerifier(address(0)), address(0));
    }

    // ---------------------------------------------------------------- PrivateReputation.register

    function test_account_insertsLeaf0() public {
        passport.register(ok(true), HN_A);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.AccountRegistered(HN_A, LEAF_A, 0);
        reputation.register(ok(true), HN_A, LEAF_A);
        assertTrue(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 1);
        assertTrue(reputation.accountTree().isKnownRoot(reputation.accountTree().root()));
    }

    function test_account_requiresHumanityFirst() public {
        vm.expectRevert(PrivateReputation.HumanityNotProven.selector);
        reputation.register(ok(true), HN_A, LEAF_A);
        assertFalse(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 0);
    }

    function test_account_replayHnReverts() public {
        passport.register(ok(true), HN_A);
        reputation.register(ok(true), HN_A, LEAF_A);
        vm.expectRevert(PrivateReputation.AlreadyRegistered.selector);
        reputation.register(ok(true), HN_A, LEAF_B);
        assertEq(reputation.accountTree().nextIndex(), 1);
    }

    function test_account_badProofIsAtomic() public {
        passport.register(ok(true), HN_A);
        vm.expectRevert(PrivateReputation.AccountNotVerified.selector);
        reputation.register(ok(false), HN_A, LEAF_A);
        assertFalse(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 0);
    }

    function test_twoHumansTwoLeaves() public {
        passport.register(ok(true), HN_A);
        reputation.register(ok(true), HN_A, LEAF_A);
        bytes32 root1 = reputation.accountTree().root();

        passport.register(ok(true), HN_B);
        reputation.register(ok(true), HN_B, LEAF_B);
        bytes32 root2 = reputation.accountTree().root();

        assertTrue(root2 != root1, "root did not move");
        assertEq(reputation.accountTree().nextIndex(), 2);
        assertTrue(passport.humanitySpent(HN_B));
        assertTrue(reputation.registeredHn(HN_B));
    }

    // ---------------------------------------------------------------- kernel identity

    function test_passport_packageId() public view {
        assertEq(passport.packageId(), PackageId.passport(address(passport)));
    }

    // ---------------------------------------------------------------- hygiene

    function test_tree_ownedByReputation() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.insert(LEAF_B);
    }

    function test_reputation_zeroConstructorArgs() public {
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            IPassport(address(0)),
            tree,
            account,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport,
            PoseidonTree(address(0)),
            account,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport,
            tree,
            IAccountVerifier(address(0)),
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport,
            tree,
            account,
            IBundleVerifier(address(0)),
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport,
            tree,
            account,
            bundle,
            IClaimVerifier(address(0)),
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport,
            tree,
            account,
            bundle,
            claimProof,
            address(0),
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
        vm.expectRevert(PrivateReputation.ZeroAddress.selector);
        new PrivateReputation(
            passport, tree, account, bundle, claimProof, FEE_TO, 0, 0, 0, 0, address(0), address(this), 0, address(0)
        );
        vm.expectRevert(PrivateReputation.BadFee.selector);
        new PrivateReputation(
            passport,
            tree,
            account,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            10_001,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
    }

    /// @dev The vault binding is deliberately NOT zero-checked: zero is a legal vault-less
    ///      deployment (a BONDS deal then fails closed in `admit`), not a wiring mistake.
    function test_reputation_vaultlessBindingIsLegal() public {
        PrivateReputation vaultless = new PrivateReputation(
            passport, tree, account, bundle, claimProof, FEE_TO, 0, 0, 0, 0, address(this), address(0), 0, address(0)
        );
        assertEq(vaultless.bondsVault(), address(0));
    }

    function test_reputation_requiresAccountsDepth() public {
        // A depth-20 tree is the notes tree of F3, never the accounts tree of a reputation.
        PoseidonTree shallow = new PoseidonTree(20, DEFAULT_ROOT_HISTORY, address(this));
        vm.expectRevert(PrivateReputation.BadTreeDepth.selector);
        new PrivateReputation(
            passport,
            shallow,
            account,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(this),
            address(this),
            0,
            address(0)
        );
    }
}
