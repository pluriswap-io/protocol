// The value gate of the notes world (PROTOCOLO.md §E.3.15.6, V3 as-built). `deposit` is the
// ONE place fresh value enters, so it is the one place a note is pinned to the public
// amount: the proof says "I know `sk_id` and `salt` such that
// `note = Poseidon(sk_id, token, amount, salt)`" — with `token` and `amount` exactly the
// public inputs the vault pulls. Every later note creation (a split's change note, a
// reabsorb's merge, a withdraw's change) is conservation-bounded inside its own circuit;
// without this binding, a 10-token deposit could insert a note committing to a million —
// the minting machine §E.3.15.6 forbids.
//
// No membership and no nullifier: the note is fresh (the vault inserts it), and a deposit
// is replayable by design — each replay inserts a distinct note for a distinct pull.
//
// The salt is DERIVED, not chosen (2026-09-23): `noteSalt(sk_id, index)` over a per-account
// deposit index, bound under 2^32 here so the recovery walk has a finite space to search. A
// deposit is the one note with no parent to derive from, so the index is its seed; everything
// downstream derives from the nullifier of what it came from. The reason is the leaf salt's,
// with more at stake — the salt is what SPENDS the note, so a salt that lived only in the
// client's local state was a note that died with the laptop.
use pluri_commitments::commitments::{note_bond, note_salt};
use pluri_commitments::vectors as v;

fn main(
    token: pub Field,
    amount: pub Field,
    note: pub Field,
    // The note's owner's secret and the deposit's index — both never revealed.
    sk_id: Field,
    index: Field,
) {
    // A zero amount deposits nothing (the vault reverts it too — fail-closed on both
    // sides of the interface), and a zero-token note could never pay any deal's lock or
    // be withdrawn (there is no token zero): both are malformed at the source.
    assert(token != 0, "zero token");
    assert(amount != 0, "zero amount");
    // The index's bound: the recovery walk tries `index = 0, 1, 2, ...` against the public
    // deposit events, so the space it searches has to be finite. 2^32 is far past any account's
    // deposit count and far below the field, which is what keeps the two seed families apart —
    // a nullifier landing inside this window has probability ~2^-222.
    let idx: u32 = index as u32;
    assert(idx as Field == index, "index too big");

    // The pinned note (§E.3.15.2, as amended in F3): token-specific, amount-pinned, and now
    // salt-derived — the three things recovery needs, all of them either public or computable.
    assert(note_bond(sk_id, token, amount, note_salt(sk_id, index)) == note, "note mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn deposit_sample_verifies() {
    // The pinned sample (vectors.json `deposit`): the builders' note — 1_500_000_000 of
    // the 6-dec pinned token, the same note the bond split later spends.
    main(
        v::DEPOSIT_TOKEN,
        v::DEPOSIT_AMOUNT,
        v::DEPOSIT_NOTE,
        v::DEPOSIT_SK_ID,
        v::DEPOSIT_INDEX,
    );
}

#[test]
fn the_salt_comes_from_the_index() {
    // The sample note is noteBond of exactly the public (token, amount) and a salt DERIVED
    // from the deposit's index — pinned straight against the generated constants.
    let salt = note_salt(v::DEPOSIT_SK_ID, v::DEPOSIT_INDEX);
    assert(salt == v::DEPOSIT_SALT, "the salt is the derivation");
    let computed = note_bond(v::DEPOSIT_SK_ID, v::DEPOSIT_TOKEN, v::DEPOSIT_AMOUNT, salt);
    assert(computed == v::DEPOSIT_NOTE, "sample note");
}

#[test(should_fail_with = "note mismatch")]
fn a_chosen_salt_has_no_proof() {
    // The point of the change: the note of a freely chosen salt is a note this circuit cannot
    // vouch for. `NOTE_SALT` is the builders' free sample value — a perfectly good field element,
    // and exactly what a non-conforming client would have used before today.
    let chosen = note_bond(v::DEPOSIT_SK_ID, v::DEPOSIT_TOKEN, v::DEPOSIT_AMOUNT, v::NOTE_SALT);
    main(v::DEPOSIT_TOKEN, v::DEPOSIT_AMOUNT, chosen, v::DEPOSIT_SK_ID, v::DEPOSIT_INDEX);
}

#[test]
fn the_deposit_is_found_again_from_the_secret() {
    // The recovery walk's first step, in-circuit terms: given `sk_id` and a deposit event
    // (token, amount — both public on-chain), the owner recomputes the note by trying indices.
    // Index 0 hits here; a real scan walks the window.
    let mut found = false;
    for i in 0..8 {
        let candidate = note_bond(
            v::DEPOSIT_SK_ID,
            v::DEPOSIT_TOKEN,
            v::DEPOSIT_AMOUNT,
            note_salt(v::DEPOSIT_SK_ID, i as Field),
        );
        found = found | (candidate == v::DEPOSIT_NOTE);
    }
    assert(found, "the note comes back from the secret and the public amount");
}
