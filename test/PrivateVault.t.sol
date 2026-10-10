// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {DeadPassportMock} from "../mocks/DeadPassportMock.sol";
import {GatingMock} from "../mocks/GatingMock.sol";
import {DepositVerifierMock} from "../mocks/DepositVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {ReabsorbVerifierMock} from "../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../mocks/WithdrawVerifierMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IPrivateReputation} from "../src/packages/interfaces/IPrivateReputation.sol";
import {IDepositVerifier} from "../src/packages/interfaces/IDepositVerifier.sol";
import {IReabsorbVerifier} from "../src/packages/interfaces/IReabsorbVerifier.sol";
import {IWithdrawVerifier} from "../src/packages/interfaces/IWithdrawVerifier.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";

/// @title Private vault tests (F3, PROTOCOLO.md §E.3.15.6)
/// @dev Notes in, locks out, everything fail-closed. The mock verifiers decode the proof as a
///      bool: a passing mock is not privacy, and nothing here claims it is.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures, sides)
///      is hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivateVaultTest is Test {
    /// @dev One side's bundle inputs as the vault reads them (§E.3.15.4). The reputation half is zero
    ///      here: these suites drive the vault directly, and a module only ever reads its own fields
    ///      — which is the property the shared verifier was designed to keep.
    function _bondIn(
        bytes32 subject,
        bytes32 forDealId,
        address tok,
        uint256 lockAmount,
        bytes32 lockCommit,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot_
    ) internal pure returns (IBundleVerifier.BundleInputs memory) {
        return IBundleVerifier.BundleInputs({
            dealSubject: subject,
            dealId: forDealId,
            token: tok,
            principal: 0,
            repRoot: bytes32(0),
            newLeaf: bytes32(0),
            nullRep: bytes32(0),
            pairTag: bytes32(0),
            lockCommit: lockCommit,
            lockAmount: lockAmount,
            changeNote: changeNote,
            nullBond: nullBond,
            bondRoot: bondRoot_,
            registryId: bytes32(0),
            hintS: bytes32(0),
            hintK: bytes32(0),
            arbiters: [bytes32(0), bytes32(0), bytes32(0)],
            verified: true
        });
    }
    BundleVerifierMock internal bundle;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant LOCK = (PRINCIPAL + 9) / 10; // §E.3.14.5, same curve as the public vault
    bytes32 internal constant DEAL_ID = keccak256("deal-1");
    bytes32 internal constant SUBJECT_H = bytes32(uint256(0x51));
    bytes32 internal constant SUBJECT_P = bytes32(uint256(0x52));
    bytes32 internal constant NOTE_H = bytes32(uint256(0x2001));
    bytes32 internal constant NOTE_P = bytes32(uint256(0x2002));
    bytes32 internal constant CHANGE_H = bytes32(uint256(0x2101));
    bytes32 internal constant CHANGE_P = bytes32(uint256(0x2102));
    bytes32 internal constant CHANGE_H2 = bytes32(uint256(0x2111));
    bytes32 internal constant LOCKCOMMIT_H = bytes32(uint256(0x3101));
    bytes32 internal constant LOCKCOMMIT_P = bytes32(uint256(0x3102));
    bytes32 internal constant LOCKCOMMIT_H2 = bytes32(uint256(0x3111));
    bytes32 internal constant NULLBOND_H1 = keccak256("nullbond-h-1");
    bytes32 internal constant NULLBOND_P1 = keccak256("nullbond-p-1");
    bytes32 internal constant NULLBOND_H2 = keccak256("nullbond-h-2");
    bytes32 internal constant REABSORB_NOTE_H = bytes32(uint256(0x2201));
    bytes32 internal constant WITHDRAW_NOTE = bytes32(uint256(0x2301));
    bytes32 internal constant FAKE_ROOT = keccak256("fake-root");
    address internal constant SINK = address(0xDEAD);
    address internal constant DEST = address(0x0DD);

    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    address internal holder;
    address internal provider;

    TestToken internal token;
    DeadPassportMock internal deadPassport;
    GatingMock internal gating;
    DepositVerifierMock internal depositProof;
    ReabsorbVerifierMock internal reabsorbProof;
    WithdrawVerifierMock internal withdrawProof;
    PrivateBondVault internal vault;
    uint256 internal deadline;

    function setUp() public {
        bundle = new BundleVerifierMock();
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        deadline = block.timestamp + 1 hours;

        token = new TestToken();
        deadPassport = new DeadPassportMock();
        gating = new GatingMock();
        depositProof = new DepositVerifierMock();
        reabsorbProof = new ReabsorbVerifierMock();
        withdrawProof = new WithdrawVerifierMock();
        // The test contract is the operator, so reserve/unlock/slash/burn are direct calls; the
        // kernel's context is exercised end-to-end in PrivateDeal.t.sol.
        vault = new PrivateBondVault(
            deadPassport, gating, SINK, address(this), depositProof, bundle, reabsorbProof, withdrawProof
        );
        // Generously funded: several tests split more than one whole note per side.
        token.mint(holder, PRINCIPAL * 100);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    function _deposit(address from, uint256 amount, bytes32 note) internal {
        vm.prank(from);
        vault.deposit(address(token), amount, note, ok(true));
    }

    /// @dev A side's package data as the kernel forwards it to `reserve` (Anexo R, 2026-09-29).
    function _bondData(bytes32 dealId_, bytes32 subject, bytes32 lockCommit, bytes32 changeNote, bytes32 nullBond)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            _bondIn(subject, dealId_, address(token), LOCK, lockCommit, changeNote, nullBond, vault.bondRoot()),
            ok(true)
        );
    }

    function _reserve(bytes32 dealId_, bytes32 subject, bytes32 lockCommit, bytes32 changeNote, bytes32 nullBond)
        internal
    {
        vault.reserve(
            subject, address(token), dealId_, PRINCIPAL, _bondData(dealId_, subject, lockCommit, changeNote, nullBond)
        );
    }

    /// @dev Both sides funded, split, and locked: the state every kernel terminal starts from.
    function _lockBoth(bytes32 dealId_) internal {
        token.mint(provider, PRINCIPAL);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(provider, PRINCIPAL, NOTE_P);
        _reserve(dealId_, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        _reserve(dealId_, SUBJECT_P, LOCKCOMMIT_P, CHANGE_P, NULLBOND_P1);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_wiresPeersAndNotesTree() public view {
        assertEq(vault.packageId(), PackageId.bonds(address(vault), SINK));
        assertEq(address(vault.passport()), address(deadPassport));
        assertEq(address(vault.reputation()), address(gating));
        assertEq(vault.sink(), SINK);
        assertEq(vault.notesTree().depth(), 20, "notes tree is depth 20 (3.15.3)");
        assertEq(vault.bondRoot(), vault.notesTree().root());
        assertTrue(vault.notesTree().isKnownRoot(vault.bondRoot()), "empty root seeded into the ring");
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            IPassport(address(0)), gating, SINK, address(this), depositProof, bundle, reabsorbProof, withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            IPrivateReputation(address(0)),
            SINK,
            address(this),
            depositProof,
            bundle,
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport, gating, address(0), address(this), depositProof, bundle, reabsorbProof, withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(deadPassport, gating, SINK, address(0), depositProof, bundle, reabsorbProof, withdrawProof);
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            IDepositVerifier(address(0)),
            bundle,
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            IBundleVerifier(address(0)),
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            bundle,
            IReabsorbVerifier(address(0)),
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            bundle,
            reabsorbProof,
            IWithdrawVerifier(address(0))
        );
    }

    // ---------------------------------------------------------------- deposit

    function test_deposit_pullsAndInsertsNote() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Deposited(address(token), holder, PRINCIPAL);
        vm.prank(holder); // the wallet and the amount are public exactly as in the public vault
        vault.deposit(address(token), PRINCIPAL, NOTE_H, ok(true));
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        assertEq(token.balanceOf(holder), PRINCIPAL * 100 - PRINCIPAL);
        assertEq(vault.notesTree().nextIndex(), 1, "the note's owner is the only thing not public");
    }

    function test_deposit_badProofIsAtomic() public {
        vm.prank(holder);
        vm.expectRevert(PrivateBondVault.DepositProofFailed.selector);
        vault.deposit(address(token), PRINCIPAL, NOTE_H, ok(false));
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(holder), PRINCIPAL * 100);
        assertEq(vault.notesTree().nextIndex(), 0);
    }

    function test_deposit_zeroAmount() public {
        vm.prank(holder);
        vm.expectRevert(PrivateBondVault.ZeroAmount.selector);
        vault.deposit(address(token), 0, NOTE_H, ok(true));
    }

    // ---------------------------------------------------------------- reserve (kernel, the split)

    /// The split happens inside the kernel's `reserve`: the source note dies, the lock is written, and the
    /// change note waits for the other side so both go into the tree together.
    function test_reserve_splitsWritesTheLockAndInsertsBothChanges() public {
        token.mint(provider, PRINCIPAL);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(provider, PRINCIPAL, NOTE_P);
        bytes memory dataH = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Reserved(DEAL_ID, SUBJECT_H, address(token), LOCK);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, dataH);
        (address lockToken, uint256 lockAmount, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockToken, address(token));
        assertEq(lockAmount, LOCK);
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertFalse(released);
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1), "the source note is dead");
        assertEq(vault.notesTree().nextIndex(), 2, "the change note waits for the other side");
        _reserve(DEAL_ID, SUBJECT_P, LOCKCOMMIT_P, CHANGE_P, NULLBOND_P1);
        assertEq(vault.notesTree().nextIndex(), 4, "both change notes, together");
    }

    function test_reserve_unprovenSplitFailsClosed() public {
        bundle.setAnswer(false); // nobody proved this side (§E.3.15.4: "bad proof" is "no ticket")
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory data = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.expectRevert(PrivateBondVault.BondProofFailed.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, data);
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0);
    }

    function test_reserve_unknownRoot() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory data = abi.encode(
            _bondIn(SUBJECT_H, DEAL_ID, address(token), LOCK, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1, FAKE_ROOT), ok(true)
        );
        vm.expectRevert(PrivateBondVault.UnknownRoot.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, data);
    }

    /// Without a split there is no lock, and without a lock the deal does not activate.
    function test_reserve_withoutASplitFailsClosed() public {
        _deposit(holder, PRINCIPAL, NOTE_H); // funded, but never split for this deal
        bytes memory noLock = abi.encode(
            _bondIn(SUBJECT_H, DEAL_ID, address(token), LOCK, bytes32(0), bytes32(0), bytes32(0), vault.bondRoot()),
            ok(true)
        );
        vm.expectRevert(PrivateBondVault.SideMismatch.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, noLock);
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0);
    }

    function test_reserve_mismatchedDealSubjectTokenOrLock() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory data = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        TestToken otherToken = new TestToken();
        vm.expectRevert(PrivateBondVault.SideMismatch.selector);
        vault.reserve(SUBJECT_H, address(otherToken), DEAL_ID, PRINCIPAL, data);
        vm.expectRevert(PrivateBondVault.SideMismatch.selector);
        vault.reserve(SUBJECT_P, address(token), DEAL_ID, PRINCIPAL, data);
        vm.expectRevert(PrivateBondVault.SideMismatch.selector);
        vault.reserve(SUBJECT_H, address(token), keccak256("deal-2"), PRINCIPAL, data);
        // A split proven for a lock that is not §E.3.14.5's: the vault must not write it, or a slash would
        // pay out more than the split ever covered.
        bytes memory overLock = abi.encode(
            _bondIn(
                SUBJECT_H, DEAL_ID, address(token), LOCK + 1, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1, vault.bondRoot()
            ),
            ok(true)
        );
        vm.expectRevert(PrivateBondVault.SideMismatch.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, overLock);
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0, "no lock was written for any mismatch");
    }

    function test_reserve_principalZero() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory data = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.expectRevert(PrivateBondVault.LockTooSmall.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, 0, data);
    }

    function test_reserve_doubleReserve() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P);
        _reserve(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        bytes memory again = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H2, CHANGE_H2, NULLBOND_H2);
        vm.expectRevert(PrivateBondVault.LockExists.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, again);
    }

    /// The same source note cannot back two locks: its nullifier dies with the first.
    function test_reserve_oneNoteOneLock() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _reserve(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        bytes memory reused = _bondData(keccak256("deal-2"), SUBJECT_H, LOCKCOMMIT_H2, CHANGE_H2, NULLBOND_H1);
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        vault.reserve(SUBJECT_H, address(token), keccak256("deal-2"), PRINCIPAL, reused);
    }

    function test_reserve_onlyOperator() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory data = _bondData(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL, data);
    }

    // ---------------------------------------------------------------- unlock (kernel)

    function test_unlock_marksReleased() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Unlocked(DEAL_ID, SUBJECT_H, address(token), LOCK);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        (,, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertTrue(released, "unlocked but parked: the tokens move only at reabsorb");
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2, "nothing left the vault");
    }

    function test_unlock_missingLock() public {
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    function test_unlock_twiceFailsClosed() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    function test_unlock_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    // ---------------------------------------------------------------- slash (kernel)

    function test_slash_paysWinnerAndReleasesWinnerLock() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Slashed(DEAL_ID, SUBJECT_P, SUBJECT_H, address(token), DEST, LOCK);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, address(0), 0);
        assertEq(token.balanceOf(DEST), LOCK, "the loser's lock went to the winner's signing address");
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - LOCK);
        (, uint256 loserAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_P);
        assertEq(loserAmount, 0, "the loser's lock is consumed, never reabsorbable");
        (,, bytes32 winnerCommit, bool winnerReleased) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertTrue(winnerReleased, "the winner's own lock is released for a later reabsorb");
        assertEq(winnerCommit, LOCKCOMMIT_H);
    }

    function test_slash_missingLock() public {
        _lockBoth(DEAL_ID);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, address(0), 0); // consumes both
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, address(0), 0);
    }

    function test_slash_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, address(0), 0);
    }

    // ---------------------------------------------------------------- the court's share (Anexo R, 2026-10-05)

    address internal constant COURT = address(0xC0DE);

    function test_slash_leavesTheCourtsShare_andPaysTheRestToTheWinner() public {
        _lockBoth(DEAL_ID);
        uint256 cut = LOCK * 3_000 / 10_000;
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, COURT, 3_000);
        assertEq(token.balanceOf(DEST), LOCK - cut, "the winner gets the rest");
        (address to, address tok, uint256 amount) = vault.shareOf(DEAL_ID);
        assertEq(to, COURT);
        assertEq(tok, address(token));
        assertEq(amount, cut);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - LOCK + cut, "the share waits in the vault");
        vm.prank(COURT);
        assertEq(vault.collect(DEAL_ID), cut);
        assertEq(token.balanceOf(COURT), cut);
    }

    /// An agreement in court: each lock is released, minus half the share, and what is reabsorbable is what the
    /// court left — the record keeps its amount (the lock commit opens to it), the cut is apart.
    function test_share_releasesBoth_minusHalfTheShareEach() public {
        _lockBoth(DEAL_ID);
        uint256 half = LOCK * 3_000 / 20_000;
        vault.share(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID, COURT, 3_000);
        (, uint256 amountH,, bool releasedH) = vault.lockOf(DEAL_ID, SUBJECT_H);
        (, uint256 amountP,, bool releasedP) = vault.lockOf(DEAL_ID, SUBJECT_P);
        assertTrue(releasedH && releasedP);
        assertEq(amountH, LOCK, "the record keeps the amount its commit opens to");
        assertEq(amountP, LOCK);
        assertEq(vault.cutOf(DEAL_ID, SUBJECT_H), half);
        assertEq(vault.cutOf(DEAL_ID, SUBJECT_P), half);
        (,, uint256 amount) = vault.shareOf(DEAL_ID);
        assertEq(amount, 2 * half);
    }

    function test_share_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.share(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID, COURT, 3_000);
    }

    function test_collect_onlyTheCourt() public {
        _lockBoth(DEAL_ID);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST, COURT, 3_000);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.collect(DEAL_ID);
    }

    // ---------------------------------------------------------------- burn (kernel)

    function test_burn_sendsBothToSink() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Burned(DEAL_ID, SUBJECT_H, SUBJECT_P, address(token), LOCK * 2);
        vault.burn(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID);
        assertEq(token.balanceOf(SINK), LOCK * 2);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - LOCK * 2);
        (, uint256 amountH,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(amountH, 0);
        (, uint256 amountP,,) = vault.lockOf(DEAL_ID, SUBJECT_P);
        assertEq(amountP, 0);
    }

    function test_burn_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.burn(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID);
    }

    // ---------------------------------------------------------------- reabsorb (the subject's)

    function test_reabsorb_requiresClaim() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    function test_reabsorb_requiresReleased() public {
        _lockBoth(DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        // Still Reserved: no kernel terminal has let this lock go.
        vm.expectRevert(PrivateBondVault.NotReleased.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    function test_reabsorb_mergesOnce() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        uint256 notesBefore = vault.notesTree().nextIndex();
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Reabsorbed(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, LOCK);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        assertEq(vault.notesTree().nextIndex(), notesBefore + 1, "the lock merged into a fresh note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H2));
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0, "the record is gone");
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    /// A lock the court took its share of comes back smaller: the proof opens the commit at the record's amount and
    /// mints what the court left, and the record and its cut are gone after.
    function test_reabsorb_afterAShare_mintsWhatTheCourtLeft() public {
        _lockBoth(DEAL_ID);
        vault.share(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID, COURT, 3_000);
        gating.setClaimed(SUBJECT_H);
        uint256 kept = LOCK - LOCK * 3_000 / 20_000;
        (,, bytes32 lockCommit,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        vm.expectCall(
            address(reabsorbProof),
            abi.encodeCall(
                reabsorbProof.verifyReabsorb,
                (DEAL_ID, SUBJECT_H, address(token), LOCK, kept, lockCommit, REABSORB_NOTE_H, NULLBOND_H2, ok(true))
            )
        );
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Reabsorbed(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, kept);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        assertEq(vault.cutOf(DEAL_ID, SUBJECT_H), 0, "the cut goes with the record");
    }

    function test_reabsorb_badProofIsAtomic() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        vm.expectRevert(PrivateBondVault.ReabsorbProofFailed.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(false));
        assertFalse(vault.notesTree().isSpent(NULLBOND_H2));
        assertEq(vault.notesTree().nextIndex(), 4, "deposit + change, both sides: nothing merged");
        (,, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertTrue(released);
    }

    function test_reabsorb_unknownSubject() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(DEAL_ID, keccak256("no-such-subject"), REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    // ---------------------------------------------------------------- withdraw (the subject's)

    function test_withdraw_exactPaysDest() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Withdrawn(address(token), DEST, PRINCIPAL, bytes32(0));
        // No change note: the note is consumed whole, and no passport was ever asked anything.
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, vault.bondRoot(), ok(true));
        assertEq(token.balanceOf(DEST), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.notesTree().nextIndex(), 1, "no change leaf for an exact consumption");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_withChangeNote() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vault.withdraw(address(token), DEST, LOCK, CHANGE_H, NULLBOND_H1, vault.bondRoot(), ok(true));
        assertEq(token.balanceOf(DEST), LOCK);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL - LOCK);
        assertEq(vault.notesTree().nextIndex(), 2, "the remainder lives on as a change note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_badProofIsAtomic() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PrivateBondVault.WithdrawProofFailed.selector);
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, root, ok(false));
        assertEq(token.balanceOf(DEST), 0);
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_nullifierReplay() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P); // a second note so the replay has something to eat
        vault.withdraw(address(token), DEST, LOCK, CHANGE_H, NULLBOND_H1, vault.bondRoot(), ok(true));
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        vault.withdraw(address(token), DEST, LOCK, CHANGE_P, NULLBOND_H1, root, ok(true));
        assertEq(token.balanceOf(DEST), LOCK, "the replay moved nothing");
    }

    function test_withdraw_unknownRoot() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.expectRevert(PrivateBondVault.UnknownRoot.selector);
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, FAKE_ROOT, ok(true));
    }

    function test_withdraw_zeroGuards() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        // Hoisted: the getter would otherwise consume the expectations.
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PrivateBondVault.ZeroAmount.selector);
        vault.withdraw(address(token), DEST, 0, bytes32(0), NULLBOND_H1, root, ok(true));
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        vault.withdraw(address(token), address(0), LOCK, CHANGE_H, NULLBOND_H1, root, ok(true));
    }

    // ---------------------------------------------------------------- the reads the vault refuses

    function test_availableAndLocked_areHidden() public {
        vm.expectRevert(PrivateBondVault.HiddenBalances.selector);
        vault.available(SUBJECT_H, address(token));
        vm.expectRevert(PrivateBondVault.HiddenBalances.selector);
        vault.locked(SUBJECT_H, address(token));
    }

    // ---------------------------------------------------------------- hygiene

    function test_notesTree_ownedByVault() public {
        // Hoisted: the getter would otherwise consume the prank and the expectation.
        PoseidonTree notes = vault.notesTree();
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        notes.insert(WITHDRAW_NOTE);
    }
}
