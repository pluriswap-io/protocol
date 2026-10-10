// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {Settlement} from "../libraries/Settlement.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IBondVault} from "./interfaces/IBondVault.sol";
import {IPrivateReputation} from "./interfaces/IPrivateReputation.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {IPoolBonds} from "./interfaces/IPoolBonds.sol";
import {IDepositVerifier} from "./interfaces/IDepositVerifier.sol";
import {IBundleVerifier} from "./interfaces/IBundleVerifier.sol";
import {IReabsorbVerifier} from "./interfaces/IReabsorbVerifier.sol";
import {IWithdrawVerifier} from "./interfaces/IWithdrawVerifier.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "./PoseidonTree.sol";

/// @title PrivateBondVault
/// @notice Skin in the game of the private packages (PROTOCOLO.md §E.3.15.6), behind the kernel's
///         `IBondVault`: same verbs the public vault answers, none of the per-subject reads.
/// @dev Value lives in notes (`note = Poseidon(sk_id, token, amount, salt)`, never in the clear),
///      earmarking lives in public deal-scoped lock records. The kernel edge is exactly
///      `IBondVault`: `passport()` for the peer check, `sink()` for the burned id, `reserve` in
///      `engage`, `unlock`/`slash`/`burn` in `runPostTerminal`. `available`/`locked` are the
///      public vault's reads; here they fail closed (`HiddenBalances`) — a per-subject aggregate
///      would link every deal of one subject, and the bond column of the cap is proven in-circuit
///      by `prepare_side`, not read here.
///
///      Flow (PROTOCOLO.md §E.3.15.4, §E.3.15.6):
///      * `deposit(token, amount, note, proof)`: the only place fresh value enters the notes. The
///        proof pins the note to the public amount; the wallet and the amount are public exactly
///        as in the public vault, the note's owner is not.
///      * `reserve` (kernel, operator-only, inside `Escrow.activate`): receives the side's proven
///        inputs as the opaque package data the kernel forwards (Anexo R, 2026-09-29). It checks the
///        split was proven in this transaction for exactly this deal, subject, token and §E.3.14.5 lock
///        — a split that under-covers its own lock would leave the vault insolvent the day that lock
///        is slashed — burns the source note (`nullBond`), writes the public lock record and, on the
///        second side, inserts both change notes together. There is no `prepare`: a split proof has
///        nowhere to execute outside an activation.
///      * `unlock` (kernel, peaceful): marks the lock released. The tokens stay parked until the
///        owner reabsorbs them — `reabsorb` is gated by `reputation.claimed(dealSubject)`: without
///        the terminal delta the lock does not come back (§E.3.15.5: the delta is atomic).
///      * `slash` (kernel, ruled): the loser's lock tokens go to the winner's signing address, minus the
///        court's share, and the loser's record is consumed; the winner's own lock is released for a later
///        reabsorb.
///      * `burn` (kernel, stalemate): both locks to the immutable sink.
///      * `share` (kernel, an agreement in court or a refused ruling): both locks released, minus half the
///        court's share each, kept apart in `cutOf` (Anexo R, 2026-10-05).
///      * `collect` (the court): the share a deal left for it.
///      * `reabsorb(dealId, ...)`: proof-gated merge of a released lock back into a fresh note — of what the court
///        left of it.
///      * `withdraw(token, dest, amount, changeNote, ...)`: proof of note ownership, no
///        `passport.identify` — the proof replaces the identification, so the vault has no
///        liveness dependency on any passport decoder.
///
///      Solvency: notes are only created by a deposit (proof-pinned to the pulled amount), by a
///      split's change note (conservation-bounded in-circuit), or by a reabsorb (the released
///      record's amount minus the court's cut, which the split covered); tokens only leave by
///      withdraw (note value), slash or burn (the record's amount), or collect (the cuts).
///
///      Peers: `passport()` satisfies the kernel's peer check; `reputation` is immutable for the
///      reabsorb gating (bound by address via `packageId`, same trust as the sink — PROTOCOLO.md
///      §E.3.15.6). The binding is reciprocal: `PrivateReputation` carries this vault's address and
///      refuses any other in `admit`, because a counterparty signs a BONDS deal trusting that the
///      lock exists — a foreign vault under the same reputation would fake that protection.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivateBondVault is IBondVault, IPoolBonds {
    using SafeERC20 for IERC20;

    /// @dev Notes tree depth (PROTOCOLO.md §E.3.15.3: 20 is the notes tree, 32 the accounts tree).
    ///      Self-deployed in the constructor: the vault is the only reader and writer of notes, so
    ///      unlike the accounts tree there is no wiring circle to break with a predicted address.
    uint8 internal constant NOTES_DEPTH = 20;

    /// @dev Transient slot of one activation, keyed by the deal: the first side's change note, held until
    ///      the second side arrives so both go into the tree together.
    bytes32 internal constant FIRST_CHANGE = keccak256("pluri:private-bond-vault:first-change");
    /// @dev Transient mark of one activation: one side is a pool, so the other side's change note has no partner to
    ///      wait for and goes into the tree alone.
    bytes32 internal constant POOL_SIDE = keccak256("pluri:private-bond-vault:pool-side");

    /// @dev The public lock record, deal-scoped (PROTOCOLO.md §E.3.15.6). `amount == 0` means "no
    ///      lock" — `reserve` rejects a zero principal, so a live record is never zero. `released`
    ///      marks a lock the kernel let go of; the tokens stay parked until the owner reabsorbs.
    struct Lock {
        address token;
        uint256 amount;
        bytes32 lockCommit;
        bool released;
    }

    IPassport public immutable passport;
    IPrivateReputation public immutable reputation;
    address public immutable sink;
    address public immutable operator;
    IDepositVerifier public immutable depositVerifier;
    /// @dev The shared verifier of §E.3.15.4. Immutable, and the module's address is its `packageId`.
    IBundleVerifier public immutable bundleVerifier;
    IReabsorbVerifier public immutable reabsorbVerifier;
    IWithdrawVerifier public immutable withdrawVerifier;
    PoseidonTree public immutable notesTree;
    bytes32 public immutable packageId;

    mapping(bytes32 dealId => mapping(bytes32 subject => Lock)) public lockOf;
    /// @dev The part of a released lock its court kept (Anexo R, 2026-10-05): the record keeps the amount its
    ///      commit opens to, and the reabsorb mints `amount - cutOf`.
    mapping(bytes32 dealId => mapping(bytes32 subject => uint256)) public cutOf;

    /// @dev What a deal left for its court, until the court collects it.
    struct Share {
        address to;
        address token;
        uint256 amount;
    }

    mapping(bytes32 dealId => Share) internal _shares;

    /// @dev The public bond accounts of official pools (Anexo R, 2026-10-05): a pool is a peer and carries a bond, but
    ///      a pool is a business with a public record, so its bond is public — no notes, no proofs. Its locks are lock
    ///      records with a zero commit, and they come back to the free balance the moment they are released.
    mapping(bytes32 subject => bool) public isPoolSubject;
    mapping(bytes32 subject => mapping(address token => uint256)) internal _poolFree;
    mapping(bytes32 subject => mapping(address token => uint256)) internal _poolLocked;

    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Reserved(bytes32 indexed dealId, bytes32 indexed subject, address token, uint256 amount);
    event Unlocked(bytes32 indexed dealId, bytes32 indexed subject, address token, uint256 amount);
    event Slashed(
        bytes32 indexed dealId, bytes32 indexed loser, bytes32 indexed winner, address token, address to, uint256 amount
    );
    event Burned(
        bytes32 indexed dealId, bytes32 indexed subjectA, bytes32 indexed subjectB, address token, uint256 amount
    );
    event PoolDeposited(address indexed pool, address indexed token, address from, uint256 amount);
    event PoolWithdrawn(address indexed pool, address indexed token, uint256 amount);
    event ShareLeft(bytes32 indexed dealId, address indexed to, address token, uint256 amount);
    event ShareCollected(bytes32 indexed dealId, address indexed to, uint256 amount);
    event Reabsorbed(bytes32 indexed dealId, bytes32 indexed subject, bytes32 newNote, uint256 amount);
    event Withdrawn(address indexed token, address indexed dest, uint256 amount, bytes32 changeNote);

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error HiddenBalances();
    error UnknownRoot();
    error DepositProofFailed();
    error BondProofFailed();
    error ReabsorbProofFailed();
    error WithdrawProofFailed();
    error SideMismatch();
    error LockExists();
    error LockTooSmall();
    error NoLock();
    error NotReleased();
    error ClaimRequired();
    error NotAPool();
    error InsufficientBond();

    constructor(
        IPassport passport_,
        IPrivateReputation reputation_,
        address sink_,
        address operator_,
        IDepositVerifier depositVerifier_,
        IBundleVerifier bundleVerifier_,
        IReabsorbVerifier reabsorbVerifier_,
        IWithdrawVerifier withdrawVerifier_
    ) {
        if (
            address(passport_) == address(0) || address(reputation_) == address(0) || sink_ == address(0)
                || operator_ == address(0) || address(depositVerifier_) == address(0)
                || address(bundleVerifier_) == address(0) || address(reabsorbVerifier_) == address(0)
                || address(withdrawVerifier_) == address(0)
        ) {
            revert ZeroAddress();
        }
        passport = passport_;
        reputation = reputation_;
        sink = sink_;
        operator = operator_;
        depositVerifier = depositVerifier_;
        bundleVerifier = bundleVerifier_;
        reabsorbVerifier = reabsorbVerifier_;
        withdrawVerifier = withdrawVerifier_;
        notesTree = new PoseidonTree(NOTES_DEPTH, DEFAULT_ROOT_HISTORY, address(this));
        packageId = PackageId.bonds(address(this), sink_);
    }

    // ------------------------------------------------------------------ kernel edge (IBondVault)

    // `packageId`, `passport` and `sink` answer through their public-immutable getters, exactly as
    // in the public vault: the auto-getters satisfy the interface, no explicit wrappers.

    /// @inheritdoc IBondVault
    /// @dev No per-subject reads exist here: a subject-scoped aggregate would link every deal of
    ///      one subject. The bond column of the cap is proven in-circuit by `prepare_side`.
    function available(bytes32, address) external pure returns (uint256) {
        revert HiddenBalances();
    }

    /// @inheritdoc IBondVault
    /// @dev Same as `available`: the public vault's reads are not this vault's language.
    function locked(bytes32, address) external pure returns (uint256) {
        revert HiddenBalances();
    }

    /// @inheritdoc IBondVault
    /// @dev `data` is `abi.encode(IBundleVerifier.BundleInputs, bytes proof)`; this module reads the inputs
    ///      and asks for the ticket the private passport's `identify` left a moment earlier. The deal's
    ///      activation fails closed without a matching split: no proof, no lock, no deal.
    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal, bytes calldata data) external {
        if (msg.sender != operator) revert Unauthorized();
        if (principal == 0) revert LockTooSmall();
        if (lockOf[dealId][subject].amount != 0) revert LockExists();
        if (isPoolSubject[subject]) return _reservePool(subject, token, dealId, principal);
        IBundleVerifier.BundleInputs memory inputs = abi.decode(data, (IBundleVerifier.BundleInputs));
        // The split must have been proven for exactly this deal, subject, token and §E.3.14.5 lock: a
        // foreign one would write a lock the source note never covered.
        uint256 lockAmount = (principal + 9) / 10;
        if (
            inputs.dealId != dealId || inputs.dealSubject != subject || inputs.token != token
                || inputs.lockAmount != lockAmount || inputs.lockCommit == bytes32(0)
        ) {
            revert SideMismatch();
        }
        if (!notesTree.isKnownRoot(inputs.bondRoot)) revert UnknownRoot();
        if (!bundleVerifier.wasProven(inputs)) revert BondProofFailed();
        // Burn the source note before anything else: concurrent splits of one note serialize here.
        notesTree.spend(inputs.nullBond);
        lockOf[dealId][subject] = Lock(token, lockAmount, inputs.lockCommit, false);
        _parkOrInsert(dealId, inputs.changeNote);
        emit Reserved(dealId, subject, token, lockAmount);
    }

    /// @dev A pool's side (Anexo R, 2026-10-05): the lock comes out of its public free bond, as a record with no
    ///      commit. The other side's change note then has no partner: if it is already parked it goes in now, and if
    ///      it comes later it goes in alone.
    function _reservePool(bytes32 subject, address token, bytes32 dealId, uint256 principal) internal {
        uint256 lockAmount = (principal + 9) / 10;
        if (_poolFree[subject][token] < lockAmount) revert InsufficientBond();
        _poolFree[subject][token] -= lockAmount;
        _poolLocked[subject][token] += lockAmount;
        lockOf[dealId][subject] = Lock(token, lockAmount, bytes32(0), false);
        bytes32 key = keccak256(abi.encode(FIRST_CHANGE, dealId));
        bytes32 parked;
        assembly ("memory-safe") {
            parked := tload(key)
        }
        if (parked != bytes32(0)) {
            assembly ("memory-safe") {
                tstore(key, 0)
            }
            notesTree.insert(parked);
        }
        bytes32 poolKey = keccak256(abi.encode(POOL_SIDE, dealId));
        assembly ("memory-safe") {
            tstore(poolKey, 1)
        }
        emit Reserved(dealId, subject, token, lockAmount);
    }

    /// @dev The first side's change note waits in transient storage; the second inserts both, adjacent. Across from a
    ///      pool there is no second note, and it goes in alone.
    function _parkOrInsert(bytes32 dealId, bytes32 change) internal {
        bytes32 poolKey = keccak256(abi.encode(POOL_SIDE, dealId));
        bool poolSide;
        assembly ("memory-safe") {
            poolSide := tload(poolKey)
        }
        if (poolSide) {
            notesTree.insert(change);
            return;
        }
        bytes32 key = keccak256(abi.encode(FIRST_CHANGE, dealId));
        bytes32 first;
        assembly ("memory-safe") {
            first := tload(key)
        }
        if (first == bytes32(0)) {
            assembly ("memory-safe") {
                tstore(key, change)
            }
            return;
        }
        assembly ("memory-safe") {
            tstore(key, 0)
        }
        bytes32[] memory notes = new bytes32[](2);
        notes[0] = first;
        notes[1] = change;
        notesTree.insertMany(notes);
    }

    /// @inheritdoc IBondVault
    /// @dev Marks the lock released; the tokens stay parked until the owner reabsorbs them
    ///      (gated by the terminal claim). Strict: a second unlock finds no live lock, which is
    ///      exactly the kernel's retry semantics — a succeeded bit is never retried.
    function unlock(bytes32 subject, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        Lock memory l = lockOf[dealId][subject];
        if (l.amount == 0 || l.released) revert NoLock();
        if (l.lockCommit == bytes32(0)) _returnPoolLock(subject, dealId, l, l.amount);
        else lockOf[dealId][subject].released = true;
        emit Unlocked(dealId, subject, token, l.amount);
    }

    /// @dev A pool's lock comes back at once: `amount` of it to the free bond, the rest already gone to the court.
    function _returnPoolLock(bytes32 subject, bytes32 dealId, Lock memory l, uint256 amount) private {
        delete lockOf[dealId][subject];
        _poolLocked[subject][l.token] -= l.amount;
        _poolFree[subject][l.token] += amount;
    }

    /// @inheritdoc IBondVault
    /// @dev The loser's lock tokens go to the winner's signing address, minus the court's share, which waits
    ///      here for the court to collect (Anexo R, 2026-10-05); the loser's record is consumed (never
    ///      reabsorbable); the winner's own lock is released for a later reabsorb, like any peaceful one.
    function slash(
        bytes32 loser,
        bytes32 winner,
        address token,
        bytes32 dealId,
        address to,
        address feeTo,
        uint256 feeBps
    ) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 loserAmount = _consume(loser, dealId);
        Lock memory w = lockOf[dealId][winner];
        if (w.amount == 0 || w.released) revert NoLock();
        if (w.lockCommit == bytes32(0)) _returnPoolLock(winner, dealId, w, w.amount);
        else lockOf[dealId][winner].released = true;
        uint256 cut = _leaveShare(dealId, token, feeTo, loserAmount * feeBps / 10_000);
        // A pool that wins keeps the payout in its bond, where its NAV reads it; anyone else is paid at `to`.
        if (isPoolSubject[winner]) _poolFree[winner][token] += loserAmount - cut;
        else IERC20(token).safeTransfer(to, loserAmount - cut);
        emit Unlocked(dealId, winner, token, w.amount);
        emit Slashed(dealId, loser, winner, token, to, loserAmount - cut);
    }

    /// @inheritdoc IBondVault
    /// @dev Both locks released, each minus half the court's share. The record keeps its amount — its commit
    ///      opens to it — and the cut is kept apart, so the reabsorb mints only what the court left.
    function share(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId, address feeTo, uint256 feeBps)
        external
    {
        if (msg.sender != operator) revert Unauthorized();
        _releaseMinus(subjectA, token, dealId, feeTo, feeBps);
        _releaseMinus(subjectB, token, dealId, feeTo, feeBps);
    }

    function _releaseMinus(bytes32 subject, address token, bytes32 dealId, address feeTo, uint256 feeBps) private {
        Lock memory l = lockOf[dealId][subject];
        if (l.amount == 0 || l.released) revert NoLock();
        uint256 cut = _leaveShare(dealId, token, feeTo, l.amount * feeBps / 20_000);
        if (l.lockCommit == bytes32(0)) {
            _returnPoolLock(subject, dealId, l, l.amount - cut);
        } else {
            lockOf[dealId][subject].released = true;
            cutOf[dealId][subject] = cut;
        }
        emit Unlocked(dealId, subject, token, l.amount - cut);
    }

    /// @inheritdoc IBondVault
    function shareOf(bytes32 dealId) external view returns (address to, address token, uint256 amount) {
        Share storage sh = _shares[dealId];
        return (sh.to, sh.token, sh.amount);
    }

    /// @inheritdoc IBondVault
    /// @dev Only the recipient: a share collected by anyone else would reach the court without the court knowing
    ///      which deal it paid for.
    function collect(bytes32 dealId) external returns (uint256 amount) {
        Share storage sh = _shares[dealId];
        if (msg.sender != sh.to) revert Unauthorized();
        amount = sh.amount;
        sh.amount = 0;
        if (amount != 0) IERC20(sh.token).safeTransfer(sh.to, amount);
        emit ShareCollected(dealId, sh.to, amount);
    }

    /// @dev Books `amount` of a lock for the court and returns it; nothing without a court.
    function _leaveShare(bytes32 dealId, address token, address feeTo, uint256 amount) private returns (uint256) {
        if (feeTo == address(0) || amount == 0) return 0;
        Share storage sh = _shares[dealId];
        sh.to = feeTo;
        sh.token = token;
        sh.amount += amount;
        emit ShareLeft(dealId, feeTo, token, amount);
        return amount;
    }

    /// @inheritdoc IBondVault
    /// @dev Both locks to the immutable sink — a stalemate's price for letting the fight expire.
    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 a = _consume(subjectA, dealId);
        uint256 b = _consume(subjectB, dealId);
        IERC20(token).safeTransfer(sink, a + b);
        emit Burned(dealId, subjectA, subjectB, token, a + b);
    }

    // ------------------------------------------------------------------ vault edge (the subject's)

    /// @notice Root of the notes tree, for proofs composed off-chain.
    function bondRoot() external view returns (bytes32) {
        return notesTree.root();
    }

    /// @notice The only place fresh value enters the notes world: pulls `amount` from the depositor
    ///         and inserts `note`, proof-pinned to the public amount. The wallet and the amount are
    ///         public exactly as in the public vault; the note's owner is not.
    function deposit(address token, uint256 amount, bytes32 note, bytes calldata proof) external {
        if (amount == 0) revert ZeroAmount();
        if (!depositVerifier.verifyDeposit(token, amount, note, proof)) revert DepositProofFailed();
        Settlement.pullExact(token, msg.sender, amount);
        notesTree.insert(note);
        emit Deposited(token, msg.sender, amount);
    }

    /// @notice Merges a released lock back into a fresh note: the proof binds the account behind
    ///         `dealSubject`, the stored `lockCommit` and the exact record amount. Gated by the
    ///         terminal claim — without the delta the lock does not come back. Permissionless.
    function reabsorb(bytes32 dealId, bytes32 dealSubject, bytes32 newNote, bytes32 nullBond, bytes calldata proof)
        external
    {
        Lock memory l = lockOf[dealId][dealSubject];
        if (l.amount == 0) revert NoLock();
        if (!l.released) revert NotReleased();
        if (!reputation.claimed(dealSubject)) revert ClaimRequired();
        // The commit opens at the record's amount; the note mints what the court left of it (Anexo R, 2026-10-05).
        uint256 kept = l.amount - cutOf[dealId][dealSubject];
        if (!reabsorbVerifier.verifyReabsorb(
                dealId, dealSubject, l.token, l.amount, kept, l.lockCommit, newNote, nullBond, proof
            )) {
            revert ReabsorbProofFailed();
        }
        notesTree.spend(nullBond);
        notesTree.insert(newNote);
        delete lockOf[dealId][dealSubject];
        delete cutOf[dealId][dealSubject];
        emit Reabsorbed(dealId, dealSubject, newNote, kept);
    }

    /// @notice Spends a note to `dest` — the proof replaces `passport.identify`, so this never
    ///         touches the passport and never links the note to any wallet. `changeNote == 0`
    ///         consumes the note whole; otherwise the remainder lives on as the change note.
    function withdraw(
        address token,
        address dest,
        uint256 amount,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot_,
        bytes calldata proof
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (dest == address(0)) revert ZeroAddress();
        if (!notesTree.isKnownRoot(bondRoot_)) revert UnknownRoot();
        if (!withdrawVerifier.verifyWithdraw(token, dest, amount, changeNote, nullBond, bondRoot_, proof)) {
            revert WithdrawProofFailed();
        }
        notesTree.spend(nullBond);
        if (changeNote != 0) notesTree.insert(changeNote);
        IERC20(token).safeTransfer(dest, amount);
        emit Withdrawn(token, dest, amount, changeNote);
    }

    /// @dev Takes a Reserved lock for good (slash's loser, burn's both): the record is deleted,
    ///      the amount returned. A released or missing lock is not takeable — the kernel's
    ///      terminals are one-shot, so anything else here is a bug or an attack, and it fails
    ///      closed.
    function _consume(bytes32 subject, bytes32 dealId) private returns (uint256 amount) {
        Lock memory l = lockOf[dealId][subject];
        if (l.amount == 0 || l.released) revert NoLock();
        delete lockOf[dealId][subject];
        if (l.lockCommit == bytes32(0)) _poolLocked[subject][l.token] -= l.amount;
        return l.amount;
    }

    // ------------------------------------------------------------------ the pools' public bonds (IPoolBonds)

    /// @inheritdoc IPoolBonds
    function depositPool(address pool, address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        bytes32 subject = _poolSubject(pool);
        Settlement.pullExact(token, msg.sender, amount);
        isPoolSubject[subject] = true;
        _poolFree[subject][token] += amount;
        emit PoolDeposited(pool, token, msg.sender, amount);
    }

    /// @inheritdoc IPoolBonds
    function withdrawPool(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        bytes32 subject = _poolSubject(msg.sender);
        if (_poolFree[subject][token] < amount) revert InsufficientBond();
        _poolFree[subject][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit PoolWithdrawn(msg.sender, token, amount);
    }

    /// @inheritdoc IPoolBonds
    function poolBondOf(address pool, address token) external view returns (uint256) {
        bytes32 subject = IPrivatePassport(address(passport)).poolSubjectOf(pool);
        return _poolFree[subject][token] + _poolLocked[subject][token];
    }

    /// @inheritdoc IPoolBonds
    function poolFreeOf(address pool, address token) external view returns (uint256) {
        return _poolFree[IPrivatePassport(address(passport)).poolSubjectOf(pool)][token];
    }

    /// @dev An official pool's subject, or `NotAPool`: the passport is the one that knows the pinned factory.
    function _poolSubject(address pool) private view returns (bytes32 subject) {
        subject = IPrivatePassport(address(passport)).poolSubjectOf(pool);
        if (subject == bytes32(0)) revert NotAPool();
    }
}
