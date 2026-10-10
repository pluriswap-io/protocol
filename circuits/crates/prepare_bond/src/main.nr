// The bond side of the activation bundle (PROTOCOLO.md §E.3.15.4 "Bond", §E.3.15.6, V3
// as-built). The proof says, in one: "I own the note behind `nullBond` — it is a live leaf
// of `bondRoot`, a note of exactly the deal's `token` worth `noteAmount`; I split it into
// `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` — the earmark whose first fold
// step IS the deal pseudonym — and `changeNote = Poseidon(sk_id, token,
// noteAmount − lockAmount, changeSalt)`; and `dealSubject = Poseidon(sk_id, dealId)`".
//
// `lockAmount` and `token` are PUBLIC (F3's amendment): the vault's `reserve` cross-checks
// the split against §E.3.14.5 (`lockAmount == (principal+9)/10`) and the deal's token — a
// hidden amount could under-cover its own lock and leave the vault insolvent the day that
// lock is slashed; a hidden token could pay an ETH lock with a USDC note.
//
// Conservation is proven here: `noteAmount ≥ lockAmount`, the change note commits to the
// exact remainder. No control-flow conditionals guard any constraint — the arithmetic
// selector shapes this pinned bb pipeline's optimized EVM verifier accepts (circuits/README.md).
use pluri_commitments::commitments::{
    deal_subject, lock_commit as lock_commit_of, lock_salt, note_bond, note_salt, null_bond,
};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    subject: pub Field,
    deal_id: pub Field,
    token: pub Field,
    lock_amount: pub Field,
    lock_commit: pub Field,
    change_note: pub Field,
    nullifier: pub Field,
    bond_root: pub Field,
    // The owner's secret and the source note's own secrets (the source salt is whatever the
    // note it spends was derived with — an index for a deposit, a parent nullifier otherwise).
    sk_id: Field,
    source_salt: Field,
    note_amount: Field,
    // Depth-20 notes-tree membership witness for the source note (§E.3.15.3).
    siblings: [Field; 20],
    indices: [u8; 20],
) {
    assert(token != 0, "zero token");
    // The same deal pseudonym every other proof of this bundle names.
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");

    // The source note: a live leaf of the notes tree, of exactly the deal's token.
    let note = note_bond(sk_id, token, note_amount, source_salt);
    assert(is_member::<20>(note, siblings, indices, bond_root), "not a live note");
    // One use per spent note (§E.3.15.3): the vault burns it before inserting the change.
    assert(null_bond(sk_id, source_salt) == nullifier, "note nullifier mismatch");

    // Conservation, in the integer domain (this nargo forbids relational ops on Field):
    // both amounts cast-checked so a truncated witness cannot pass, the lock positive
    // (§E.3.14.5's lock of a live principal is never zero) and never over its note.
    let na: u128 = note_amount as u128;
    assert(na as Field == note_amount, "note amount too big");
    let la: u128 = lock_amount as u128;
    assert(la as Field == lock_amount, "lock amount too big");
    assert(la >= 1, "zero lock");
    assert(na >= la, "lock over the note");

    // The split's two salts are DERIVED (2026-09-23), not chosen: the lock's from the deal it
    // belongs to (one lock per deal per subject — which is what lets `reabsorb` rebuild its whole
    // witness from the public record), the change's from the nullifier this very proof publishes.
    // So both children of a split are re-derivable by anyone holding `sk_id` and reading the chain,
    // and neither needs a note kept on the side.
    let lock_s = lock_salt(sk_id, deal_id);
    let change_s = note_salt(sk_id, nullifier);

    // The split (§E.3.15.4): the earmark and the change, both bound to the public lockAmount.
    assert(lock_commit_of(sk_id, deal_id, lock_amount, lock_s) == lock_commit, "lock commit mismatch");
    assert(
        note_bond(sk_id, token, note_amount - lock_amount, change_s) == change_note,
        "change note mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn prepare_bond_sample_verifies() {
    // The pinned sample (vectors.json `bond`): the builders' 1_500_000_000 note splits for
    // the prepare deal's §E.3.14.5 lock (10_000_000 = (100_000_000+9)/10), the change note
    // carrying the exact 1_490_000_000 remainder.
    assert(v::BOND_DEPTH == 20, "notes tree depth");
    main(
        v::BOND_DEAL_SUBJECT,
        v::BOND_DEAL_ID,
        v::BOND_TOKEN,
        v::BOND_LOCK_AMOUNT,
        v::BOND_LOCK_COMMIT,
        v::BOND_CHANGE_NOTE,
        v::BOND_NULL_BOND,
        v::BOND_ROOT,
        v::BOND_SK_ID,
        v::BOND_SOURCE_SALT,
        v::BOND_NOTE_AMOUNT,
        v::BOND_SIBLINGS,
        v::BOND_INDICES,
    );
}

#[test]
fn both_children_derive_from_what_they_came_from() {
    // The split's two salts, neither of them chosen: the lock's from the deal it belongs to,
    // the change's from the nullifier this proof publishes. So the owner finds both again by
    // following the edges the chain already shows — the source note burns, and the burn's own
    // nullifier names the change it produced.
    assert(lock_salt(v::BOND_SK_ID, v::BOND_DEAL_ID) == v::BOND_LOCK_SALT, "the lock's salt is the deal's");
    assert(null_bond(v::BOND_SK_ID, v::BOND_SOURCE_SALT) == v::BOND_NULL_BOND, "the source burns");
    assert(note_salt(v::BOND_SK_ID, v::BOND_NULL_BOND) == v::BOND_CHANGE_SALT, "and seeds the change");
}

#[test]
fn split_is_conservation() {
    // The sample's own arithmetic, pinned straight: the lock is §E.3.14.5's exact lock of
    // the prepare principal, the change the exact remainder — the two halves sum back to
    // the source note's amount.
    // §E.3.14.5's lock, as INTEGER arithmetic (untyped literals are Fields in Noir — and
    // field division is not truncation, so the lock must be computed in u64).
    let principal: u64 = 100000000;
    let lock: u64 = (principal + 9) / 10;
    assert(v::BOND_LOCK_AMOUNT == lock as Field, "lock is (principal+9)/10");
    assert(v::BOND_LOCK_AMOUNT + (v::BOND_NOTE_AMOUNT - v::BOND_LOCK_AMOUNT) == v::BOND_NOTE_AMOUNT, "halves sum");
    // And the change note is a note of exactly that remainder.
    let computed = note_bond(
        v::BOND_SK_ID,
        v::BOND_TOKEN,
        v::BOND_NOTE_AMOUNT - v::BOND_LOCK_AMOUNT,
        v::BOND_CHANGE_SALT,
    );
    assert(computed == v::BOND_CHANGE_NOTE, "change note");
}
