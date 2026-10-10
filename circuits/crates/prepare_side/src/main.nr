// One side of an activation bundle, in ONE proof (PROTOCOLO.md §E.3.15.4, as-built 2026-09-23).
//
// It says everything the three per-module proofs said between them: "I am the account behind
// `dealSubject`; my leaf is live under `repRoot`; the deal fits the cap my own stats buy; here is
// the transition and the version nullifier that burns; and — when the deal carries bonds — here is
// the split of one of my notes into this deal's earmark and its change".
//
// WHY ONE INSTEAD OF THREE. Measured: `prepare_passport` 42.5k gates, `prepare_admit` 58.9k,
// `prepare_bond` 34.6k — and a third of that is the same work done three times. All three prove
// `dealSubject = Poseidon(sk_id, dealId)`; passport and admit BOTH prove membership of the same leaf
// under the same root, a depth-32 walk each. Merging deletes the duplication instead of hiding it.
//
// What it buys is not mostly gas. A rollup charges for the bytes that reach L1, and six proofs of
// ~9 KB are the dominant cost of a private deal; two are not. Verification follows (three verifies
// per side become one), and the proving time comes out slightly BELOW three separate proofs, so the
// user waits less rather than more — which is what ruled out the other way of getting here,
// recursive aggregation: one in-circuit Honk verification alone is 681k gates, five times this
// whole circuit.
//
// THE BOND IS OPTIONAL, and selected the way §E.3.14.7 already selects the bond column of the cap
// table: `lockCommit != 0`. A deal without bonds proves the same statement with the note half
// masked out — the hashing still runs (a circuit has no branches) and costs about 9k gates it does
// not need, which is 60 ms of proving nobody will notice. The alternative, two circuit variants,
// buys that back and doubles the verifiers, the fixtures and the ways to get it wrong.
//
// THREE ADDITIONS (Anexo R, 2026-09-29), all public inputs appended after the bond half:
//   * the pair tag is blinded by `pair_secret`, a `k` the two sides pick for this deal, so whoever
//     collected several counterparties' `S` cannot test pairs of them against the tags;
//   * `hint_s` / `hint_k` publish the counterparty's `S` and that `k` under a pad only this account can
//     rebuild (`hint_key(sk_id, dealId, …)`), so its counterparty tree comes back from `sk_id` and the
//     chain — the recovery the counterparty tree used to break;
//   * `arbiters` are the humanity nullifiers of the deal's panel (zeros without one), and the side proves
//     its own — `hn(sk_id, registry_id)`, the same human the account was registered under — is none of
//     them: the arbiter is not a party, at the level of the human.
//
// AND ONE MORE (2026-10-01, the open accounts): `verified`, the leaf's own flag, made public. It is what
// the reputation reads to decide whether the deal can CREDIT — only between two verified sides — and an
// open account cannot carry a bond: the bond column of the cap is a verified account's.
use pluri_commitments::commitments::{
    account_commitment, deal_subject, hint_key, hn, leaf_rep, leaf_salt, lock_commit as lock_commit_of, lock_salt,
    note_bond, note_salt, null_bond, null_rep, pair_tag as pair_tag_of,
};
use pluri_commitments::merkle::{compute_root, is_member};
use pluri_commitments::tiers;
use pluri_commitments::vectors as v;

fn main(
    // ---- the deal, as the kernel and every module already know it
    subject: pub Field,
    deal_id: pub Field,
    token: pub Field,
    principal: pub Field,
    decimals: pub Field,
    // ---- the reputation side
    rep_root: pub Field,
    new_leaf: pub Field,
    nullifier: pub Field,
    pair_tag: pub Field,
    // ---- the bond side; `lock_commit == 0` is a deal without bonds and masks all of it
    lock_commit: pub Field,
    lock_amount: pub Field,
    change_note: pub Field,
    null_bond_out: pub Field,
    bond_root: pub Field,
    // ---- the recovery hints and the panel (2026-09-29)
    registry_id: pub Field,
    hint_s: pub Field,
    hint_k: pub Field,
    arbiters: pub [Field; 3],
    // ---- whether a proof of humanity stands behind this account (the leaf's flag, 2026-10-01)
    verified: pub Field,
    // ---- the secret, once for all three statements
    sk_id: Field,
    s_other: Field,
    pair_secret: Field,
    // ---- the account's current leaf (§E.3.15.3 leafRep order)
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
    rec_count: Field,
    rec_volume: Field,
    rep_siblings: [Field; 32],
    rep_indices: [u8; 32],
    // ---- the note being split, when there is one
    source_salt: Field,
    note_amount: Field,
    note_siblings: [Field; 20],
    note_indices: [u8; 20],
) {
    assert(token != 0, "zero token");

    // ---------------------------------------------------------------- the account, once
    // Three proofs used to derive this separately. The passport statement IS this line plus the
    // membership below: identity is "a live leaf of the account tree", nothing more.
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    let s = account_commitment(sk_id);

    // The pair of §E.3.14.7, named by both sides at once, blinded by the secret they picked together.
    assert(pair_secret != 0, "an unblinded pair tag");
    assert(pair_tag_of(s, s_other, deal_id, pair_secret) == pair_tag, "pair tag mismatch");
    assert(s_other != s, "a deal with yourself is not a counterparty");

    // What this account must remember about the deal, published under its own pad.
    assert(hint_s == s_other + hint_key(sk_id, deal_id, 1), "counterparty hint mismatch");
    assert(hint_k == pair_secret + hint_key(sk_id, deal_id, 2), "pair secret hint mismatch");

    // The arbiter is not a party: the human behind this account is none of the panel's. The account was
    // registered with `hsk == sk_id` (register_account), so `hn(sk_id, registry_id)` is that human's
    // nullifier; the court checks `registry_id` is its own.
    let me = hn(sk_id, registry_id);
    for i in 0..3 {
        assert(me != arbiters[i], "a party sits on the panel");
    }

    // ---------------------------------------------------------------- the flag
    // A bit, and a verified one when the deal carries a bond: an open account has no bond column.
    assert(verified * (1 - verified) == 0, "verified is a bit");
    let bonded = lock_commit != 0;
    assert((bonded as Field) * (1 - verified) == 0, "bonds need a passport");

    // ---------------------------------------------------------------- the leaf, once
    let same_token = leaf_token == token;
    let genesis = (leaf_token == 0)
        & (count == 0)
        & (volume == 0)
        & (penalty == 0)
        & (in_flight == 0)
        & (rec_count == 0)
        & (rec_volume == 0);
    assert(same_token | genesis, "leaf is neither this token's nor the genesis leaf");

    let leaf = leaf_rep(
        s,
        count,
        volume,
        penalty,
        in_flight,
        leaf_token,
        leaf_salt(sk_id, version),
        version,
        cp_root,
        epoch,
        epoch_credits,
        rec_count,
        rec_volume,
        verified,
    );
    // The one membership both the passport and the admission statements needed.
    assert(is_member::<32>(leaf, rep_siblings, rep_indices, rep_root), "not a live account leaf");

    // ---------------------------------------------------------------- the cap (§E.3.14.7, in-circuit)
    // The CREDIT buys the cap (`count`, `volume`), never the record: an open account's record grows,
    // its credit does not, and it stays at T1 whatever it has done.
    let sc = tiers::score(count, volume, penalty, decimals);
    let cap_raw = tiers::cap_raw(sc, bonded, decimals);
    let inf: u64 = in_flight as u64;
    assert(inf as Field == in_flight, "in_flight too big");
    let prin: u64 = principal as u64;
    assert(prin as Field == principal, "principal too big");
    let cap_v: u128 = cap_raw as u128;
    assert(cap_v as Field == cap_raw, "cap too big");
    assert((inf as u128) + (prin as u128) <= cap_v, "inFlight + principal over the tier cap");

    // ---------------------------------------------------------------- the transition
    assert(
        leaf_rep(
            s,
            count,
            volume,
            penalty,
            in_flight + principal,
            token,
            leaf_salt(sk_id, version + 1),
            version + 1,
            cp_root,
            epoch,
            epoch_credits,
            rec_count,
            rec_volume,
            verified,
        )
            == new_leaf,
        "new leaf mismatch",
    );
    assert(null_rep(sk_id, version) == nullifier, "version nullifier mismatch");

    // ---------------------------------------------------------------- the bond, masked
    // `b` is 1 for a bonded deal and 0 otherwise, and every bond assertion is written as
    // "b * (this - that) == 0": true by construction when there is no bond, and the real equation
    // when there is. No branch, for the codegen reason circuits/README.md records.
    let b: Field = bonded as Field;

    let note = note_bond(sk_id, token, note_amount, source_salt);
    let note_root = compute_root::<20>(note, note_siblings, note_indices);
    assert(b * (note_root - bond_root) == 0, "not a live note");
    assert(b * (null_bond(sk_id, source_salt) - null_bond_out) == 0, "note nullifier mismatch");

    // Conservation. The casts are unconditional (they only ever reject an unrepresentable witness),
    // the comparisons are masked: a deal without bonds carries zeros and must not be held to them.
    let na: u128 = note_amount as u128;
    assert(na as Field == note_amount, "note amount too big");
    let la: u128 = lock_amount as u128;
    assert(la as Field == lock_amount, "lock amount too big");
    let lock_ok = (la >= 1) & (na >= la);
    assert(b * (1 - lock_ok as Field) == 0, "lock is zero or over the note");

    // The split's two derived salts (§E.3.15.6) and the two commitments they open.
    let lock_s = lock_salt(sk_id, deal_id);
    let change_s = note_salt(sk_id, null_bond_out);
    assert(b * (lock_commit_of(sk_id, deal_id, lock_amount, lock_s) - lock_commit) == 0, "lock commit mismatch");
    assert(
        b * (note_bond(sk_id, token, note_amount - lock_amount, change_s) - change_note) == 0,
        "change note mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

/// The pinned side with its bond half as given, and the panel as given.
fn sample(
    lock_commit: Field,
    lock_amount: Field,
    change_note: Field,
    null_bond_out: Field,
    bond_root: Field,
    source_salt: Field,
    note_amount: Field,
    note_siblings: [Field; 20],
    note_indices: [u8; 20],
    arbiters: [Field; 3],
) {
    main(
        v::PREPARE_DEAL_SUBJECT,
        v::PREPARE_DEAL_ID,
        v::PREPARE_TOKEN,
        v::PREPARE_PRINCIPAL,
        v::PREPARE_DECIMALS,
        v::PREPARE_ROOT,
        v::PREPARE_NEW_LEAF,
        v::PREPARE_NULL_REP,
        v::PREPARE_PAIR_TAG,
        lock_commit,
        lock_amount,
        change_note,
        null_bond_out,
        bond_root,
        v::PREPARE_REGISTRY_ID,
        v::PREPARE_HINT_S,
        v::PREPARE_HINT_K,
        arbiters,
        1, // the registry account: a verified one
        v::PREPARE_SK_ID,
        v::PREPARE_CP_S,
        v::PREPARE_PAIR_SECRET,
        0,
        0,
        0,
        0,
        0, // leaf0: the genesis branch
        0,
        v::PREPARE_CP_ROOT,
        0,
        0,
        0,
        0,
        v::PREPARE_SIBLINGS,
        v::PREPARE_INDICES,
        source_salt,
        note_amount,
        note_siblings,
        note_indices,
    );
}

fn bonded(arbiters: [Field; 3]) {
    sample(
        v::SIDE_LOCK_COMMIT,
        v::SIDE_LOCK_AMOUNT,
        v::SIDE_CHANGE_NOTE,
        v::SIDE_NULL_BOND,
        v::SIDE_BOND_ROOT,
        v::SIDE_SOURCE_SALT,
        v::SIDE_NOTE_AMOUNT,
        v::SIDE_NOTE_SIBLINGS,
        v::SIDE_NOTE_INDICES,
        arbiters,
    );
}

/// The pinned sample, with the bond half live: the registry account's genesis leaf admits the
/// prepare deal's principal AND splits the deposited note for that same deal's lock. Three proofs'
/// worth of statement, one call — and every constant below comes from the `prepare` and `bond`
/// sections unchanged, which is the argument in a nutshell: they were always one deal.
#[test]
fn a_bonded_side_verifies() {
    bonded(v::PREPARE_ARBITERS);
}

/// The same side WITHOUT bonds: `lockCommit == 0` masks the whole note half, so the zeros that a
/// deal with no vault carries are not held to anything. It also moves the cap to the base column —
/// the sample's 100 units fit under T1's 250 either way, which is why one sample can walk both.
#[test]
fn an_unbonded_side_verifies_with_the_note_half_masked() {
    sample(0, 0, 0, 0, 0, 0, 0, [0; 20], [0; 20], v::PREPARE_ARBITERS);
}

/// A deal without a panel carries zeros where the arbiters go, and no human is zero.
#[test]
fn a_side_without_a_panel_verifies() {
    bonded([0; 3]);
}

/// What the merge must NOT lose: a bonded side still has to prove its note. Claiming a lock without
/// a live note behind it is exactly the statement `prepare_bond` existed to make, and masking must
/// not have turned it into an opinion.
#[test(should_fail_with = "not a live note")]
fn a_bonded_side_still_needs_its_note() {
    sample(
        v::SIDE_LOCK_COMMIT,
        v::SIDE_LOCK_AMOUNT,
        v::SIDE_CHANGE_NOTE,
        v::SIDE_NULL_BOND,
        v::SIDE_BOND_ROOT,
        v::SIDE_SOURCE_SALT,
        v::SIDE_NOTE_AMOUNT + 1, // a note the tree never held
        v::SIDE_NOTE_SIBLINGS,
        v::SIDE_NOTE_INDICES,
        v::PREPARE_ARBITERS,
    );
}

/// The human behind this account sits on the panel: there is no proof for that side.
#[test(should_fail_with = "a party sits on the panel")]
fn a_party_cannot_be_an_arbiter() {
    bonded([v::PREPARE_ARBITERS[0], v::PREPARE_OWN_HN, v::PREPARE_ARBITERS[2]]);
}

/// An open side (2026-10-01): an account without a Passport, at its genesis, takes the same deal under the
/// T1 base cap — no bond. Its proof says `verified = 0`, which is what keeps the deal from crediting.
fn open_side(verified: Field, lock_commit: Field) {
    main(
        v::OPEN_DEAL_SUBJECT,
        v::PREPARE_DEAL_ID,
        v::PREPARE_TOKEN,
        v::PREPARE_PRINCIPAL,
        v::PREPARE_DECIMALS,
        v::OPEN_ROOT,
        v::OPEN_NEW_LEAF,
        v::OPEN_NULL_REP,
        v::OPEN_PAIR_TAG,
        lock_commit,
        0,
        0,
        0,
        0,
        v::PREPARE_REGISTRY_ID,
        v::OPEN_HINT_S,
        v::OPEN_HINT_K,
        v::PREPARE_ARBITERS,
        verified,
        v::OPEN_SK_ID,
        v::OPEN_CP_S,
        v::PREPARE_PAIR_SECRET,
        0,
        0,
        0,
        0,
        0,
        0,
        v::PREPARE_CP_ROOT,
        0,
        0,
        0,
        0,
        v::OPEN_SIBLINGS,
        v::OPEN_INDICES,
        0,
        0,
        [0; 20],
        [0; 20],
    );
}

#[test]
fn an_open_side_verifies_without_a_bond() {
    open_side(0, 0);
}

/// The flag is the leaf's: an open account cannot present itself as verified.
#[test(should_fail_with = "not a live account leaf")]
fn an_open_side_cannot_pass_for_verified() {
    open_side(1, 0);
}

/// Bonds are a verified account's: the open side is refused before its note is even looked at.
#[test(should_fail_with = "bonds need a passport")]
fn an_open_side_cannot_carry_a_bond() {
    open_side(0, v::SIDE_LOCK_COMMIT);
}

#[test(should_fail_with = "verified is a bit")]
fn the_side_flag_is_a_bit() {
    open_side(2, 0);
}
