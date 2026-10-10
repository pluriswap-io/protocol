// The exit of the notes world (PROTOCOLO.md §E.3.15.6, V3 as-built). The proof says, in
// one: "I own the note behind `nullBond` — a live leaf of `bondRoot`, a note of exactly
// the public `token` worth `noteAmount`; `noteAmount = amount + changeAmount`; and
// `changeNote = Poseidon(sk_id, token, changeAmount, changeSalt)` — or zero when `amount`
// consumes the note whole". The vault pays `dest` and burns the note; the change note,
// when any, lives on.
//
// `dest` is a public input the proof binds — any address the owner names, named in the
// proof itself: the proof replaces `passport.identify` (§E.3.15.6), so the vault never
// touches the passport, and a relayer cannot redirect a withdraw it did not prove.
//
// The whole-consumption branch is ARITHMETIC, not control flow — the selector keeps the
// constraint shape inside what this pinned bb pipeline's optimized EVM verifier accepts
// (circuits/README.md): `changeNote == (1 − whole) * noteBond(..., changeAmount, ...)`
// — zero exactly when the note is consumed whole, the computed change note otherwise.
use pluri_commitments::commitments::{note_bond, note_salt, null_bond};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    token: pub Field,
    dest: pub Field,
    amount: pub Field,
    change_note: pub Field,
    nullifier: pub Field,
    bond_root: pub Field,
    // The owner's secret and the spent note's own secrets (the source salt is whatever the note
    // it spends was derived with — an index for a deposit, a parent nullifier otherwise).
    sk_id: Field,
    source_salt: Field,
    note_amount: Field,
    // Depth-20 notes-tree membership witness for the spent note (§E.3.15.3).
    siblings: [Field; 20],
    indices: [u8; 20],
) {
    assert(token != 0, "zero token");
    // The vault rejects both already; the proof pins them too — fail-closed on both
    // sides of the interface.
    assert(dest != 0, "zero dest");
    let amt: u128 = amount as u128;
    assert(amt as Field == amount, "amount too big");
    assert(amt >= 1, "zero amount");

    // The spent note: a live leaf of the notes tree, of exactly the public token.
    let note = note_bond(sk_id, token, note_amount, source_salt);
    assert(is_member::<20>(note, siblings, indices, bond_root), "not a live note");
    // One use per spent note (§E.3.15.3).
    assert(null_bond(sk_id, source_salt) == nullifier, "note nullifier mismatch");

    // Conservation (§E.3.15.6): the withdraw never exceeds the note — the change is the
    // exact remainder, and no negative change can exist.
    let na: u128 = note_amount as u128;
    assert(na as Field == note_amount, "note amount too big");
    assert(na >= amt, "withdraw over the note");
    let change_amount = note_amount - amount;

    // The change note — whole consumption masks it to zero (§E.3.15.6's amendment). Its salt is
    // DERIVED (2026-09-23) from the nullifier this proof publishes: the change of a withdraw is
    // found again by following the same edge the chain shows, never from a client's local state.
    let computed_change = note_bond(sk_id, token, change_amount, note_salt(sk_id, nullifier));
    let whole = (amount == note_amount) as Field;
    assert(change_note == (1 - whole) * computed_change, "change note mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn withdraw_sample_verifies() {
    // The pinned sample (vectors.json `withdraw`): the bond split's change note
    // (1_490_000_000) spends 400_000_000 to the pinned dest, the 1_090_000_000 remainder
    // living on as a second change note — against the tree root the reabsorb's insert
    // produced (the e2e order: deposit -> split -> reabsorb -> withdraw).
    assert(v::WITHDRAW_DEPTH == 20, "notes tree depth");
    main(
        v::WITHDRAW_TOKEN,
        v::WITHDRAW_DEST,
        v::WITHDRAW_AMOUNT,
        v::WITHDRAW_CHANGE_NOTE,
        v::WITHDRAW_NULL_BOND,
        v::WITHDRAW_ROOT,
        v::WITHDRAW_SK_ID,
        v::WITHDRAW_SOURCE_SALT,
        v::WITHDRAW_NOTE_AMOUNT,
        v::WITHDRAW_SIBLINGS,
        v::WITHDRAW_INDICES,
    );
}

#[test]
fn whole_consumption_takes_zero_change() {
    // The other branch (§E.3.15.6's amendment): the same note, the SAME membership witness,
    // withdrawn whole — the change note must be zero, and the conservation's own
    // arithmetic says it: amount == noteAmount masks the computed change to zero.
    let computed_change = note_bond(
        v::WITHDRAW_SK_ID,
        v::WITHDRAW_TOKEN,
        v::WITHDRAW_NOTE_AMOUNT - v::WITHDRAW_NOTE_AMOUNT,
        v::WITHDRAW_CHANGE_SALT,
    );
    let whole = (v::WITHDRAW_NOTE_AMOUNT == v::WITHDRAW_NOTE_AMOUNT) as Field;
    let masked = (1 - whole) * computed_change;
    assert(masked == 0, "whole consumption masks the change to zero");
    main(
        v::WITHDRAW_TOKEN,
        v::WITHDRAW_DEST,
        v::WITHDRAW_NOTE_AMOUNT, // the whole note, in one withdraw
        0, // changeNote == 0: nothing lives on
        v::WITHDRAW_NULL_BOND,
        v::WITHDRAW_ROOT,
        v::WITHDRAW_SK_ID,
        v::WITHDRAW_SOURCE_SALT,
        v::WITHDRAW_NOTE_AMOUNT,
        v::WITHDRAW_SIBLINGS,
        v::WITHDRAW_INDICES,
    );
}

#[test]
fn the_change_is_seeded_by_the_burn() {
    // The withdraw's change salt, derived from the nullifier this proof publishes: the note that
    // lives on is found again from the note that died, with nothing kept on the side.
    assert(null_bond(v::WITHDRAW_SK_ID, v::WITHDRAW_SOURCE_SALT) == v::WITHDRAW_NULL_BOND, "the source burns");
    assert(note_salt(v::WITHDRAW_SK_ID, v::WITHDRAW_NULL_BOND) == v::WITHDRAW_CHANGE_SALT, "and seeds the change");
}

#[test]
fn the_change_is_the_exact_remainder() {
    // The sample's own arithmetic, pinned straight: the second change note commits to
    // exactly noteAmount − amount — conservation as a hash, against the generated constant.
    let computed = note_bond(
        v::WITHDRAW_SK_ID,
        v::WITHDRAW_TOKEN,
        v::WITHDRAW_NOTE_AMOUNT - v::WITHDRAW_AMOUNT,
        v::WITHDRAW_CHANGE_SALT,
    );
    assert(computed == v::WITHDRAW_CHANGE_NOTE, "change note");
}
