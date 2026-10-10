// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";

contract ReputationTest is Test {
    /// @dev A fresh deal id / counterparty per call: these tests predate the 2026-09-23 rule that credit
    ///      is once per counterparty, and they all mean "another deal with somebody new". The ones that
    ///      mean "the same somebody again" say so by passing a fixed tag.
    uint256 private _tagNonce;

    function _dealTag() internal returns (bytes32) {
        return keccak256(abi.encode("deal", ++_tagNonce));
    }

    function _cpTag() internal returns (bytes32) {
        return keccak256(abi.encode("counterparty", ++_tagNonce));
    }
    uint256 internal constant UNIT = 250 * 1e6;
    bytes32 internal constant SUBJECT_H = keccak256("subject-h");
    address internal holder = address(0xA11CE);
    address internal holder2 = address(0xA11CE2);
    address internal feeRecipient = address(0xFEE);

    TestToken internal token;
    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        reputation = new Reputation(passport, feeRecipient, 30, 60, 100, 10_000_000, address(this));
        vault = new BondVault(address(this), address(0xdeaD), passport);
        passport.setHuman(holder, SUBJECT_H);
        token.mint(holder, 10_000_000);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(Reputation.ZeroAddress.selector);
        new Reputation(IPassport(address(0)), feeRecipient, 1, 1, 0, 0, address(this));
        vm.expectRevert(Reputation.ZeroAddress.selector);
        new Reputation(passport, address(0), 1, 1, 0, 0, address(this));
        vm.expectRevert(Reputation.ZeroAddress.selector);
        new Reputation(passport, feeRecipient, 1, 1, 0, 0, address(0));
    }

    function test_constructor_rejectsBpsOverMax() public {
        vm.expectRevert(Reputation.BadFee.selector);
        new Reputation(passport, feeRecipient, 1, 1, 10_001, 0, address(this));
        vm.expectRevert(Reputation.BadFee.selector);
        new Reputation(passport, feeRecipient, 10_001, 1, 0, 0, address(this));
        vm.expectRevert(Reputation.BadFee.selector);
        new Reputation(passport, feeRecipient, 1, 10_001, 0, 0, address(this));
    }

    function test_packageId_passportAndReputationStable() public view {
        assertEq(passport.packageId(), PackageId.passport(address(passport)));
        assertEq(
            reputation.packageId(), PackageId.reputation(address(reputation), feeRecipient, 30, 60, 100, 10_000_000)
        );
    }

    function test_invoice_declaredInPackage() public view {
        (uint256 act, address actTo) = reputation.invoiceActivation(UNIT);
        (uint256 done, address doneTo) = reputation.invoiceCompletion(UNIT);
        (uint256 contest, address contestTo) = reputation.invoiceContest(1_000_000_000);
        assertEq(act, 750_000, "0.3% of 250");
        assertEq(done, 1_500_000, "0.6% of 250");
        assertEq(contest, 10_000_000); // 1% of 1000 USDC = 10, at the floor
        (uint256 contestBig,) = reputation.invoiceContest(2_000_000_000);
        assertEq(contestBig, 20_000_000); // 1% of 2000 USDC
        assertEq(actTo, feeRecipient);
        assertEq(doneTo, feeRecipient);
        assertEq(contestTo, feeRecipient);
    }

    function test_identify_twoWalletsShareSubject() public {
        passport.setHuman(holder2, SUBJECT_H);
        assertEq(passport.identify(holder, holder, bytes32(0), ""), SUBJECT_H);
        assertEq(passport.identify(holder2, holder2, bytes32(0), ""), SUBJECT_H);
        reputation.admit(holder, _dealTag(), address(token), UNIT / 2, address(0), "");
        reputation.admit(holder2, _dealTag(), address(token), UNIT / 2, address(0), "");
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), UNIT);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder2, _dealTag(), address(token), 1, address(0), "");
    }

    function test_admit_onlyOperator() public {
        vm.prank(holder);
        vm.expectRevert(Reputation.Unauthorized.selector);
        reputation.admit(holder, _dealTag(), address(token), 1, address(0), "");
    }

    function test_notifyTerminal_onlyOperator() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        vm.prank(holder);
        vm.expectRevert(Reputation.Unauthorized.selector);
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Peaceful);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), UNIT);
    }

    function test_noPassport_noAdmit() public {
        vm.expectRevert(IPassport.NoPassport.selector);
        reputation.admit(address(0xB0B), _dealTag(), address(token), 1, address(0), "");
    }

    function test_notify_unknownSubject_inFlightUnderflow() public {
        vm.expectRevert(Reputation.InFlightUnderflow.selector);
        reputation.notifyTerminal(keccak256("nobody"), _cpTag(), address(token), 1, IReputation.Close.Peaceful);
    }

    function test_notify_usesSubject_afterPassportRevoked() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        passport.setHuman(holder, bytes32(0));
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Peaceful);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
        assertEq(reputation.score(SUBJECT_H, address(token)), 2);
    }

    function test_t1Cap() public {
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, _dealTag(), address(token), UNIT + 1, address(0), "");
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), UNIT);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, _dealTag(), address(token), 1, address(0), "");
    }

    function test_withBond_t1Cap400() public {
        uint256 capBond = 400 * 1e6;
        token.mint(holder, capBond);
        vm.prank(holder);
        vault.deposit(SUBJECT_H, address(token), capBond);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, _dealTag(), address(token), capBond + 1, address(vault), "");
        reputation.admit(holder, _dealTag(), address(token), capBond, address(vault), "");
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), capBond);
    }

    function test_withBond_insufficientAvailable() public {
        vm.expectRevert(Reputation.InsufficientBond.selector);
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(vault), "");
    }

    function test_notifyPeaceful_updatesScore() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Peaceful);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 1);
        assertEq(penalty, 0);
        assertEq(volume, UNIT);
        assertEq(reputation.score(SUBJECT_H, address(token)), 2);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
    }

    function test_notifySilent_noScore() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Silent);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 0);
        assertEq(penalty, 0);
        assertEq(volume, 0);
        assertEq(reputation.score(SUBJECT_H, address(token)), 0);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
    }

    function test_notifyStalemate_penaltyFive() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Stalemate);
        (, uint32 penalty,) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 5);
        assertEq(reputation.score(SUBJECT_H, address(token)), 0);
    }

    /// A dispute nobody gave a tribunal and nobody settled (Anexo R, 2026-09-24): +10 to each side, between
    /// a tribunal's refusal (+5) and a proven loss (+15).
    function test_notifyDeadlock_penaltyTen() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Deadlock);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 10);
        assertEq(count, 0, "a deadlock closed no trade");
        assertEq(volume, 0);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0, "the flight is released like any terminal");
    }

    /// A Provider who let the fiat clock run out, or cancelled on his own (Anexo R, 2026-09-28): +5, like one
    /// bad clock, and the flight released.
    function test_notifyNoShow_penaltyFive() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.NoShow);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 5);
        assertEq(count, 0, "nothing was traded");
        assertEq(volume, 0);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
    }

    function test_notifyArb_winNoVolume_lossPenaltyFifteen() public {
        reputation.admit(holder, _dealTag(), address(token), UNIT / 2, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT / 2, IReputation.Close.ArbWin);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 0);
        assertEq(penalty, 0);
        assertEq(volume, 0);
        reputation.admit(holder, _dealTag(), address(token), UNIT / 2, address(0), "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT / 2, IReputation.Close.ArbLoss);
        (, penalty,) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 15);
    }

    function test_fivePeaceful_t2Cap() public {
        for (uint256 i; i < 5; i++) {
            reputation.admit(holder, _dealTag(), address(token), UNIT, address(0), "");
            reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Peaceful);
        }
        assertEq(reputation.score(SUBJECT_H, address(token)), 10);
        uint256 t2 = 500 * 1e6;
        reputation.admit(holder, _dealTag(), address(token), t2, address(0), "");
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), t2);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, _dealTag(), address(token), 1, address(0), "");
    }

    function test_trio_peacefulUnlocksBond() public {
        bytes32 dealId = keccak256("deal-trio");
        token.mint(holder, UNIT / 10);
        vm.prank(holder);
        vault.deposit(SUBJECT_H, address(token), UNIT / 10);
        reputation.admit(holder, _dealTag(), address(token), UNIT, address(vault), "");
        vault.reserve(SUBJECT_H, address(token), dealId, UNIT, "");
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), UNIT, IReputation.Close.Peaceful);
        vault.unlock(SUBJECT_H, address(token), dealId);
        vm.prank(holder);
        vault.withdraw(SUBJECT_H, address(token), UNIT / 10);
        assertEq(token.balanceOf(holder), 10_000_000 + UNIT / 10);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
        assertEq(reputation.score(SUBJECT_H, address(token)), 2);
    }

    function test_notifyTerminal_doesNotRevertEscrow() public {
        TerminalHarness escrow = new TerminalHarness();
        escrow.releaseThenNotify(reputation, address(0xB0B), address(token), 1);
        assertEq(uint8(escrow.status()), uint8(TerminalHarness.Status.RELEASED));
    }
}

contract TerminalHarness {
    enum Status {
        NONE,
        RELEASED
    }

    Status public status;

    function releaseThenNotify(Reputation r, address wallet, address token, uint256 principal) external {
        status = Status.RELEASED;
        try r.notifyTerminal(
            bytes32(uint256(uint160(wallet))),
            keccak256("harness-counterparty"),
            token,
            principal,
            IReputation.Close.Peaceful
        ) {}
            catch {}
    }
}
