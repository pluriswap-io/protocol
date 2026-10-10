// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestToken} from "../../mocks/TestToken.sol";
import {DeadPassportMock} from "../../mocks/DeadPassportMock.sol";
import {GatingMock} from "../../mocks/GatingMock.sol";
import {DepositVerifierMock} from "../../mocks/DepositVerifierMock.sol";
import {BundleVerifierMock} from "../../mocks/BundleVerifierMock.sol";
import {ReabsorbVerifierMock} from "../../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../../mocks/WithdrawVerifierMock.sol";
import {PoseidonTree} from "../../src/packages/PoseidonTree.sol";
import {PrivateBondVault} from "../../src/packages/PrivateBondVault.sol";
import {PoseidonSingletons} from "../PoseidonSingletons.sol";
import {IBundleVerifier} from "../../src/packages/interfaces/IBundleVerifier.sol";

/// @title Private vault invariant handler (F3 closure, PROTOCOLO.md §E.3.15.6)
/// @dev The vault is explored directly: the handler plays the prover side (deposits, splits,
///      reabsorbs, withdrawals — fresh roots, honest-circuit arithmetic) and the operator side
///      (reserve — which is where a side's split happens since 2026-09-29 — and unlock/slash/burn) with arbitrary, interleaved sequences
///      over a growing book of deals. HandlerBase is not extended: this vault never touches the
///      escrow, and the kernel's side of the edge is deterministic (PrivateDeal.t.sol drives it
///      end-to-end, including the court-ruled slash).
///
///      The handler models the HONEST circuit: every split conserves its source note
///      (`change + lock == note`), every reabsorb mints exactly the record's amount, every
///      withdrawal pays out exactly what its note gave. The invariants then prove the
///      contract-layer half of solvency: with honest proofs, the vault can never owe more than
///      it holds. The circuit's half (a dishonest prover cannot forge those conservation
///      relations) is the real verifier's job — a mock cannot stand in for it.
///
///      Every verb guards its full precondition and is a no-op otherwise (`fail_on_revert = true`:
///      any revert in a campaign is a vault finding, not handler noise).
contract PrivateVaultHandler is Test {
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

    uint256 internal constant MIN_AMOUNT = 1;
    uint256 internal constant MAX_AMOUNT = 1_000_000_000;
    address internal constant PAYEE = address(0x0DD);

    /// @dev One live note of one subject: the leaf the tree holds, and the value the honest
    ///      circuit says it commits to.
    struct Note {
        bytes32 leaf;
        uint256 value;
    }

    /// @dev One side of one deal: the lock record, and whether the kernel has let the lock go.
    struct Side {
        uint256 lock;
        bool released;
    }

    struct Deal {
        bytes32 id;
        Side h;
        Side p;
    }

    uint256[2] internal pks = [0xA11CE, 0xB0B];
    bytes32[2] internal subjects = [bytes32(uint256(0x51)), bytes32(uint256(0x52))];

    TestToken public token;
    PrivateBondVault public vault;
    GatingMock public gating;

    Note[][2] internal notes;
    Deal[] internal deals;
    uint256 internal nonce;

    // Ghost books, re-derived from first principles by the invariants.
    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;
    uint256 public ghost_slashed;
    uint256 public ghost_burned;
    uint256 public ghost_notesValue;
    uint256 public ghost_locksValue;

    mapping(string => uint256) public calls;

    constructor() {
        token = new TestToken();
        gating = new GatingMock();
        bundle = new BundleVerifierMock();
        vault = new PrivateBondVault(
            new DeadPassportMock(),
            gating,
            address(0xDEAD),
            address(this), // the handler is the kernel here: the operator side of the edge
            new DepositVerifierMock(),
            bundle,
            new ReabsorbVerifierMock(),
            new WithdrawVerifierMock()
        );
    }

    // --- accessors for the invariants ---------------------------------------------------------------

    function dealsLength() external view returns (uint256) {
        return deals.length;
    }

    /// @dev Flattened deal book, so the state-equivalence invariant needs no struct returns.
    function dealAt(uint256 i) external view returns (bytes32 id, uint256 lockH, bool relH, uint256 lockP, bool relP) {
        Deal storage d = deals[i];
        return (d.id, d.h.lock, d.h.released, d.p.lock, d.p.released);
    }

    function subjectAt(uint8 who) external view returns (bytes32) {
        return subjects[who % 2];
    }

    function walletOf(uint8 who) public view returns (address) {
        return vm.addr(pks[who % 2]);
    }

    function subjectOf(uint8 who) internal view returns (bytes32) {
        return subjects[who % 2];
    }

    // --- prover side ---------------------------------------------------------------------------------

    function deposit(uint8 who, uint256 amount) external {
        who = uint8(who % 2);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        address wallet = walletOf(who);
        token.mint(wallet, amount);
        bytes32 leaf = _fresh();
        vm.startPrank(wallet);
        token.approve(address(vault), amount);
        vault.deposit(address(token), amount, leaf, _ok());
        vm.stopPrank();
        _born(who, leaf, amount);
        ghost_deposited += amount;
        calls["deposit"]++;
    }

    function withdraw(uint8 who, uint256 noteSeed, uint256 amountSeed) external {
        who = uint8(who % 2);
        Note[] storage pool = notes[who];
        (uint256 noteIdx, bool found) = _pickSpendable(pool, noteSeed);
        if (!found) return;
        Note memory note = pool[noteIdx];
        uint256 amount = bound(amountSeed, 1, note.value);
        uint256 change = note.value - amount;
        bytes32 changeLeaf = change == 0 ? bytes32(0) : _fresh();
        vault.withdraw(address(token), PAYEE, amount, changeLeaf, _fresh(), vault.bondRoot(), _ok());
        _spent(who, note);
        if (change != 0) _born(who, changeLeaf, change);
        ghost_withdrawn += amount;
        calls["withdraw"]++;
    }

    // --- operator side (the kernel's verbs) ----------------------------------------------------------

    /// @dev A deal's activation, as the kernel runs it: both sides reserve in one call, each splitting a
    ///      note of its own — the source dies, the lock is written, the change is born — and the two change
    ///      notes go into the tree together on the second (Anexo R, 2026-09-29). There is no other way for
    ///      a split to happen, so the handler never models one side alone.
    function reserve(uint256 noteSeedH, uint256 noteSeedP, uint256 lockSeed) external {
        (uint256 iH, bool foundH) = _pickSpendable(notes[0], noteSeedH);
        (uint256 iP, bool foundP) = _pickSpendable(notes[1], noteSeedP);
        if (!foundH || !foundP) return;
        Note memory nH = notes[0][iH];
        Note memory nP = notes[1][iP];
        uint256 lockAmount = bound(lockSeed, 1, nH.value < nP.value ? nH.value : nP.value);
        deals.push(Deal({id: keccak256(abi.encode("inv-deal", ++nonce)), h: Side(0, false), p: Side(0, false)}));
        Deal storage d = deals[deals.length - 1];
        bytes32 changeH = _fresh();
        bytes32 changeP = _fresh();
        // principal = 10 * lock keeps (principal + 9) / 10 == lock exactly. `_fresh()` stands in for the
        // lock commitment (an opaque value for the books) and the source note's nullifier.
        bytes memory dataH = abi.encode(
            _bondIn(subjectOf(0), d.id, address(token), lockAmount, _fresh(), changeH, _fresh(), vault.bondRoot()),
            _ok()
        );
        bytes memory dataP = abi.encode(
            _bondIn(subjectOf(1), d.id, address(token), lockAmount, _fresh(), changeP, _fresh(), vault.bondRoot()),
            _ok()
        );
        vault.reserve(subjectOf(0), address(token), d.id, lockAmount * 10, dataH);
        vault.reserve(subjectOf(1), address(token), d.id, lockAmount * 10, dataP);
        // Honest-circuit conservation: each source note becomes change + lock.
        _spent(0, nH);
        _spent(1, nP);
        _born(0, changeH, nH.value - lockAmount);
        _born(1, changeP, nP.value - lockAmount);
        d.h.lock = lockAmount;
        d.p.lock = lockAmount;
        ghost_locksValue += 2 * lockAmount;
        calls["reserve"]++;
    }

    function unlock(uint256 seed) external {
        (uint256 d, uint8 s, bool found) = _findReserved(seed);
        if (!found) return;
        vault.unlock(subjectOf(s), address(token), deals[d].id);
        _side(deals[d], s).released = true;
        calls["unlock"]++;
    }

    /// @dev Needs both sides reserved: the kernel only rules a live fight.
    function slash(uint256 seed, uint256 loserSeed) external {
        (uint256 d, bool found) = _findBothReserved(seed);
        if (!found) return;
        uint8 loser = uint8(loserSeed % 2);
        uint8 winner = 1 - loser;
        uint256 loserLock = _side(deals[d], loser).lock;
        vault.slash(subjectOf(loser), subjectOf(winner), address(token), deals[d].id, PAYEE, address(0), 0);
        _consumeSide(deals[d], loser);
        _side(deals[d], winner).released = true;
        ghost_slashed += loserLock;
        calls["slash"]++;
    }

    function burn(uint256 seed) external {
        (uint256 d, bool found) = _findBothReserved(seed);
        if (!found) return;
        uint256 a = deals[d].h.lock;
        uint256 b = deals[d].p.lock;
        vault.burn(subjectOf(0), subjectOf(1), address(token), deals[d].id);
        _consumeSide(deals[d], 0);
        _consumeSide(deals[d], 1);
        ghost_burned += a + b;
        calls["burn"]++;
    }

    /// @dev The user claimed the terminal delta (the gating mock flips), then merges the released
    ///      lock back into a fresh note of the same value.
    function reabsorb(uint256 seed) external {
        (uint256 d, uint8 s, bool found) = _findReleased(seed);
        if (!found) return;
        uint256 amount = _side(deals[d], s).lock;
        bytes32 newNote = _fresh();
        gating.setClaimed(subjectOf(s));
        vault.reabsorb(deals[d].id, subjectOf(s), newNote, _fresh(), _ok());
        _consumeSide(deals[d], s);
        _born(s, newNote, amount);
        calls["reabsorb"]++;
    }

    // --- pickers ---------------------------------------------------------------------------------------

    /// @dev A note that can still fund something: a zero-value change note is a legitimate leaf
    ///      (a whole-note split), but it can back neither a lock nor a withdrawal.
    function _pickSpendable(Note[] storage pool, uint256 seed) internal view returns (uint256 idx, bool found) {
        uint256 n = pool.length;
        if (n == 0) return (0, false);
        uint256 start = seed % n;
        for (uint256 k; k < n; k++) {
            idx = (start + k) % n;
            if (pool[idx].value != 0) return (idx, true);
        }
        return (0, false);
    }

    function _side(Deal storage d, uint8 s) internal view returns (Side storage) {
        return s == 0 ? d.h : d.p;
    }

    /// @dev A side whose lock is live and not yet released, ready for the kernel's unlock.
    function _findReserved(uint256 seed) internal view returns (uint256 d, uint8 s, bool found) {
        uint256 n = deals.length;
        if (n == 0) return (0, 0, false);
        uint256 start = seed % n;
        for (d = 0; d < n; d++) {
            uint256 i = (start + d) % n;
            for (uint256 k; k < 2; k++) {
                Side storage side = _side(deals[i], uint8(k));
                if (side.lock != 0 && !side.released) return (i, uint8(k), true);
            }
        }
        return (0, 0, false);
    }

    /// @dev A deal whose both locks are live and reserved.
    function _findBothReserved(uint256 seed) internal view returns (uint256 d, bool found) {
        uint256 n = deals.length;
        if (n == 0) return (0, false);
        uint256 start = seed % n;
        for (d = 0; d < n; d++) {
            uint256 i = (start + d) % n;
            if (deals[i].h.lock != 0 && !deals[i].h.released && deals[i].p.lock != 0 && !deals[i].p.released) {
                return (i, true);
            }
        }
        return (0, false);
    }

    /// @dev A side whose lock is live and released by the kernel, ready to reabsorb.
    function _findReleased(uint256 seed) internal view returns (uint256 d, uint8 s, bool found) {
        uint256 n = deals.length;
        if (n == 0) return (0, 0, false);
        uint256 start = seed % n;
        for (d = 0; d < n; d++) {
            uint256 i = (start + d) % n;
            for (uint256 k; k < 2; k++) {
                Side storage side = _side(deals[i], uint8(k));
                if (side.lock != 0 && side.released) return (i, uint8(k), true);
            }
        }
        return (0, 0, false);
    }

    // --- bookkeeping -----------------------------------------------------------------------------------

    function _born(uint8 who, bytes32 leaf, uint256 value) internal {
        notes[who].push(Note(leaf, value));
        ghost_notesValue += value;
    }

    function _spent(uint8 who, Note memory note) internal {
        Note[] storage pool = notes[who];
        for (uint256 i; i < pool.length; i++) {
            if (pool[i].leaf == note.leaf) {
                pool[i] = pool[pool.length - 1];
                pool.pop();
                ghost_notesValue -= note.value;
                return;
            }
        }
    }

    function _consumeSide(Deal storage d, uint8 s) internal {
        Side storage side = _side(d, s);
        ghost_locksValue -= side.lock;
        side.lock = 0;
        side.released = false;
    }

    function _fresh() internal returns (bytes32) {
        return bytes32(++nonce);
    }

    function _ok() internal pure returns (bytes memory) {
        return abi.encode(true);
    }
}

/// @title Private vault invariants (F3 closure, PROTOCOLO.md §E.3.15.6)
/// @dev Two first-principles books and one state-machine equivalence:
///      * token conservation — the vault's balance is exactly deposits minus withdrawals, slashes
///        and burns. Tokens never appear or vanish.
///      * claims backed — every live claim (notes + lock records) is covered by tokens on hand.
///      * books match — the contract's own records equal the handler's model, deal by deal, side
///        by side: no verb corrupts a record it did not touch.
contract PrivateVaultInvariantTest is Test {
    PrivateVaultHandler internal h;

    function setUp() public {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        h = new PrivateVaultHandler();

        bytes4[] memory sel = new bytes4[](11);
        sel[0] = PrivateVaultHandler.deposit.selector;
        sel[1] = PrivateVaultHandler.deposit.selector;
        sel[2] = PrivateVaultHandler.deposit.selector;
        sel[3] = PrivateVaultHandler.reserve.selector;
        sel[4] = PrivateVaultHandler.reserve.selector;
        sel[5] = PrivateVaultHandler.reserve.selector;
        sel[6] = PrivateVaultHandler.unlock.selector;
        sel[7] = PrivateVaultHandler.slash.selector;
        sel[8] = PrivateVaultHandler.burn.selector;
        sel[9] = PrivateVaultHandler.reabsorb.selector;
        sel[10] = PrivateVaultHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    function invariant_tokenConservation() public view {
        uint256 expected = h.ghost_deposited() - h.ghost_withdrawn() - h.ghost_slashed() - h.ghost_burned();
        assertEq(
            h.token().balanceOf(address(h.vault())),
            expected,
            "vault balance != deposits - withdrawals - slashes - burns"
        );
    }

    function invariant_claimsBacked() public view {
        uint256 claims = h.ghost_notesValue() + h.ghost_locksValue();
        assertGe(h.token().balanceOf(address(h.vault())), claims, "live claims exceed the tokens on hand");
    }

    function invariant_booksMatchModel() public view {
        PrivateBondVault vault = h.vault();
        for (uint256 i; i < h.dealsLength(); i++) {
            (bytes32 id, uint256 lockH, bool relH, uint256 lockP, bool relP) = h.dealAt(i);
            (, uint256 lockAmountH, bytes32 commitH, bool releasedH) = vault.lockOf(id, h.subjectAt(0));
            (, uint256 lockAmountP, bytes32 commitP, bool releasedP) = vault.lockOf(id, h.subjectAt(1));
            assertEq(lockAmountH, lockH, "holder lock drifted from the model");
            assertEq(lockAmountP, lockP, "provider lock drifted from the model");
            assertEq(releasedH, relH, "holder release drifted from the model");
            assertEq(releasedP, relP, "provider release drifted from the model");
            if (lockH != 0) assertTrue(commitH != 0, "live holder lock lost its commitment");
            if (lockP != 0) assertTrue(commitP != 0, "live provider lock lost its commitment");
        }
    }

    function afterInvariant() public view {
        console2.log("deals/deposited/withdrawn", h.dealsLength(), h.ghost_deposited(), h.ghost_withdrawn());
        console2.log("slashed/burned/notesValue", h.ghost_slashed(), h.ghost_burned(), h.ghost_notesValue());
        console2.log("locksValue", h.ghost_locksValue());
    }
}
