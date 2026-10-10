// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";

contract BondVaultTest is Test {
    uint256 internal constant PRINCIPAL = 1_000_000;
    bytes32 internal constant SUBJECT = keccak256("subject-h");
    bytes32 internal constant SUBJECT_P = keccak256("subject-p");

    TestToken internal token;
    PassportMock internal passport;
    BondVault internal vault;
    address internal sink = address(0xdeaD);
    address internal holder = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal controller = address(0xC0);
    address internal otherWallet = address(0xA11CE2);

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        vault = new BondVault(address(this), sink, passport);
        passport.setHuman(holder, SUBJECT);
        passport.setHuman(provider, SUBJECT_P);
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function test_packageId_bondsPreimageStable() public view {
        assertEq(vault.packageId(), PackageId.bonds(address(vault), sink));
        assertEq(PackageId.BOND_LOCK_BPS, 1000);
    }

    function test_deposit() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        assertEq(token.balanceOf(holder), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
    }

    function test_withdrawAvailable() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(holder), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), 0);
        assertEq(vault.available(SUBJECT, address(token)), 0);
    }

    function test_withdrawRequiresSubject() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vm.prank(provider);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        vm.prank(controller);
        vm.expectRevert(IPassport.NoPassport.selector);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
    }

    function test_withdrawSharedBySameHuman() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        passport.setHuman(otherWallet, SUBJECT);
        vm.prank(otherWallet);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(otherWallet), PRINCIPAL);
        assertEq(vault.available(SUBJECT, address(token)), 0);
    }

    function test_lockTenPercent() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        bytes32 dealId = keccak256("deal-1");
        vault.reserve(SUBJECT, address(token), dealId, PRINCIPAL, "");
        uint256 lockAmount = PRINCIPAL / 10;
        assertEq(vault.lockOf(SUBJECT, dealId), lockAmount);
        assertEq(vault.locked(SUBJECT, address(token)), lockAmount);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL - lockAmount);
        assertTrue(vault.locked(SUBJECT, address(token)) * 10 >= PRINCIPAL);
    }

    function test_twoDealsLockSum() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), keccak256("deal-a"), PRINCIPAL / 2, "");
        vault.reserve(SUBJECT, address(token), keccak256("deal-b"), PRINCIPAL / 2, "");
        assertEq(vault.locked(SUBJECT, address(token)), PRINCIPAL / 10);
        assertTrue(vault.locked(SUBJECT, address(token)) * 10 >= PRINCIPAL);
    }

    function test_withdrawLockedReverts() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), keccak256("deal-1"), PRINCIPAL, "");
        vm.prank(holder);
        vm.expectRevert(BondVault.InsufficientAvailable.selector);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        uint256 avail = PRINCIPAL - PRINCIPAL / 10;
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), avail);
        assertEq(vault.available(SUBJECT, address(token)), 0);
        assertEq(vault.locked(SUBJECT, address(token)), PRINCIPAL / 10);
    }

    function test_unlockPeaceful() public {
        bytes32 dealId = keccak256("deal-unlock");
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), dealId, PRINCIPAL, "");
        vm.prank(holder);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.unlock(SUBJECT, address(token), dealId);
        vault.unlock(SUBJECT, address(token), dealId);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(holder), PRINCIPAL);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(BondVault.ZeroAddress.selector);
        new BondVault(address(0), sink, passport);
        vm.expectRevert(BondVault.ZeroAddress.selector);
        new BondVault(address(this), address(0), passport);
        vm.expectRevert(BondVault.ZeroAddress.selector);
        new BondVault(address(this), sink, IPassport(address(0)));
    }

    function test_slashToWinnerSigningAddress() public {
        bytes32 dealId = keccak256("deal-slash");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, holder, address(0), 0);
        assertEq(token.balanceOf(holder), lockAmount);
        assertEq(token.balanceOf(controller), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.locked(SUBJECT_P, address(token)), 0);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
        assertEq(vault.deposited(SUBJECT_P, address(token)), PRINCIPAL - lockAmount);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - lockAmount);
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(holder), lockAmount + PRINCIPAL);
    }

    function test_slashPaysControllerWhenControllerIsTheHolder() public {
        bytes32 dealId = keccak256("deal-ctrl");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, controller, address(0), 0);
        assertEq(token.balanceOf(controller), lockAmount, "winner's signing address is paid, whoever it is");
        assertEq(token.balanceOf(sink), 0, "nothing burns on a ruled slash");
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.available(SUBJECT_P, address(token)), PRINCIPAL - lockAmount);
    }

    // --- the court's share (Anexo R, 2026-10-05) ---------------------------------------------------------

    address internal court = address(0xC0DE);

    function test_slash_leavesTheCourtsShare_andPaysTheRestToTheWinner() public {
        bytes32 dealId = keccak256("deal-share");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        uint256 cut = lockAmount * 3_000 / 10_000;
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, holder, court, 3_000);
        assertEq(token.balanceOf(holder), lockAmount - cut, "the winner gets the rest");
        assertEq(vault.deposited(SUBJECT_P, address(token)), PRINCIPAL - lockAmount, "the whole lock left the loser");
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL, "the winner's own lock came back whole");
        (address to, address tok, uint256 amount) = vault.shareOf(dealId);
        assertEq(to, court);
        assertEq(tok, address(token));
        assertEq(amount, cut);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - lockAmount + cut, "the share waits in the vault");
    }

    function test_share_eachSideLeavesHalf_andGetsTheRestBack() public {
        bytes32 dealId = keccak256("deal-shared");
        _lockBoth(dealId);
        uint256 half = (PRINCIPAL / 10) * 3_000 / 20_000;
        vault.share(SUBJECT, SUBJECT_P, address(token), dealId, court, 3_000);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL - half);
        assertEq(vault.available(SUBJECT_P, address(token)), PRINCIPAL - half);
        (,, uint256 amount) = vault.shareOf(dealId);
        assertEq(amount, 2 * half);
    }

    function test_share_withoutACourt_isAPlainUnlock() public {
        bytes32 dealId = keccak256("deal-no-court");
        _lockBoth(dealId);
        vault.share(SUBJECT, SUBJECT_P, address(token), dealId, address(0), 3_000);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.available(SUBJECT_P, address(token)), PRINCIPAL);
        (,, uint256 amount) = vault.shareOf(dealId);
        assertEq(amount, 0);
    }

    function test_collect_onlyTheCourt_once() public {
        bytes32 dealId = keccak256("deal-collect");
        _lockBoth(dealId);
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, holder, court, 3_000);
        uint256 cut = (PRINCIPAL / 10) * 3_000 / 10_000;
        vm.prank(holder);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.collect(dealId);
        vm.prank(court);
        assertEq(vault.collect(dealId), cut);
        assertEq(token.balanceOf(court), cut);
        vm.prank(court);
        assertEq(vault.collect(dealId), 0, "collected once");
    }

    function test_stalemateBurnsBoth() public {
        bytes32 dealId = keccak256("deal-burn");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        vault.burn(SUBJECT, SUBJECT_P, address(token), dealId);
        assertEq(token.balanceOf(sink), lockAmount * 2);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
        assertEq(vault.locked(SUBJECT_P, address(token)), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), PRINCIPAL - lockAmount);
        assertEq(vault.deposited(SUBJECT_P, address(token)), PRINCIPAL - lockAmount);
        assertEq(token.balanceOf(controller), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_reserveOnlyOperator() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vm.prank(holder);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.reserve(SUBJECT, address(token), keccak256("deal-1"), PRINCIPAL, "");
    }

    function _lockBoth(bytes32 dealId) internal {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        token.mint(provider, PRINCIPAL);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        vault.deposit(SUBJECT_P, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), dealId, PRINCIPAL, "");
        vault.reserve(SUBJECT_P, address(token), dealId, PRINCIPAL, "");
    }
}
