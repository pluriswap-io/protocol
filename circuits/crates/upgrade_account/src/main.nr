// An open account becomes a verified one (PROTOCOLO.md §E.3.15.3, 2026-10-01). The proof says, in one:
// "I am the human behind `h_n` — the nullifier the passport burned a moment ago in this bundle — and I
// own a live OPEN account leaf under `repRoot`; `newLeaf` is that same leaf, every stat carried over, its
// flag set, its version bumped and its salt re-derived; `nullRep(v)` is the current version's nullifier".
//
// What it buys is continuity, not a clean slate. An open account trades without a Passport: its record
// grows, its penalties land, and nothing it does buys tier. Verifying later keeps all of that — the
// record, the penalties, the counterparty tree — and from then on its deals with other verified accounts
// can credit. The credit it never earned while open stays unearned: the flag does not reach back.
//
// The binding is the register bundle's (register_account), with the leaf already in the tree instead of
// a genesis: knowing `hsk` behind `h_n` is what ties the human to this account, and one human verifies
// one account — the module marks `h_n` exactly as `register` does, so a human who registered a verified
// account cannot also verify an open one, and vice versa.
use pluri_commitments::commitments::{account_commitment, hn, leaf_rep, leaf_salt, null_rep};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    h_n: pub Field,
    registry_id: pub Field,
    rep_root: pub Field,
    nullifier: pub Field,
    new_leaf: pub Field,
    hsk: Field,
    sk_id: Field,
    // The current leaf (§E.3.15.3 leafRep order), open by construction: `verified` is not a witness.
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
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The human: the same nullifier the humanity circuit derived.
    assert(hn(hsk, registry_id) == h_n, "hn mismatch");

    let s = account_commitment(sk_id);
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
        0,
    );
    // An OPEN leaf of this account, live: a verified one has nothing to upgrade.
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live open leaf");
    // The current version's nullifier: the upgrade burns it like any other transition, so it serializes
    // against an activation or a claim of the same version.
    assert(null_rep(sk_id, version) == nullifier, "version nullifier mismatch");

    // The same account, one flag different. Every stat rides through — in particular the penalties and the
    // flight of a deal still open: its claim will run against this leaf.
    assert(
        leaf_rep(
            s,
            count,
            volume,
            penalty,
            in_flight,
            leaf_token,
            leaf_salt(sk_id, version + 1),
            version + 1,
            cp_root,
            epoch,
            epoch_credits,
            rec_count,
            rec_volume,
            1,
        )
            == new_leaf,
        "upgraded leaf mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

/// The pinned open account (vectors `open`), at its genesis, verified by the registry sample human.
fn sample(new_leaf: Field, hsk: Field, root: Field) {
    main(
        v::REGISTRY_SAMPLE_HN,
        v::REGISTRY_ID,
        root,
        v::OPEN_NULL_REP,
        new_leaf,
        hsk,
        v::OPEN_SK_ID,
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
    );
}

#[test]
fn an_open_account_is_verified_in_place() {
    sample(v::UPGRADE_NEW_LEAF, v::REGISTRY_HSK, v::OPEN_ROOT);
}

#[test]
fn the_upgraded_leaf_is_the_same_account_flagged() {
    let expected = leaf_rep(
        account_commitment(v::OPEN_SK_ID),
        0,
        0,
        0,
        0,
        0,
        leaf_salt(v::OPEN_SK_ID, 1),
        1,
        v::PREPARE_CP_ROOT,
        0,
        0,
        0,
        0,
        1,
    );
    assert(expected == v::UPGRADE_NEW_LEAF, "upgrade leaf");
}

#[test(should_fail_with = "hn mismatch")]
fn somebody_else_cannot_verify_it() {
    sample(v::UPGRADE_NEW_LEAF, v::REGISTRY_HSK + 1, v::OPEN_ROOT);
}

#[test(should_fail_with = "not a live open leaf")]
fn a_verified_account_has_nothing_to_upgrade() {
    // The registry sample's genesis is verified: proving it as an open leaf finds no such leaf.
    main(
        v::REGISTRY_SAMPLE_HN,
        v::REGISTRY_ID,
        v::PREPARE_ROOT,
        v::PREPARE_NULL_REP,
        v::UPGRADE_NEW_LEAF,
        v::REGISTRY_HSK,
        v::PREPARE_SK_ID,
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
        v::PREPARE_SIBLINGS,
        v::PREPARE_INDICES,
    );
}

#[test(should_fail_with = "upgraded leaf mismatch")]
fn the_upgrade_cannot_touch_the_stats() {
    // A leaf that came out with something more than the flag — here, one more recorded deal — has no proof.
    let doctored = leaf_rep(
        account_commitment(v::OPEN_SK_ID),
        0,
        0,
        0,
        0,
        0,
        leaf_salt(v::OPEN_SK_ID, 1),
        1,
        v::PREPARE_CP_ROOT,
        0,
        0,
        1,
        0,
        1,
    );
    sample(doctored, v::REGISTRY_HSK, v::OPEN_ROOT);
}

#[test]
fn a_record_and_a_penalty_ride_through() {
    // The open account after its first deal (vectors `claim_open` → `open` attest leaf): one recorded deal,
    // nothing credited. Upgraded, it keeps exactly that.
    let carried = leaf_rep(
        account_commitment(v::OPEN_SK_ID),
        0,
        0,
        0,
        0,
        v::ATTEST_TOKEN,
        leaf_salt(v::OPEN_SK_ID, 3),
        3,
        v::OPEN_CP_ROOT,
        v::OPEN_EPOCH,
        0,
        1,
        v::OPEN_PRINCIPAL,
        1,
    );
    main(
        v::REGISTRY_SAMPLE_HN,
        v::REGISTRY_ID,
        v::OPEN_ATTEST_ROOT,
        v::OPEN_NULL_REP_2,
        carried,
        v::REGISTRY_HSK,
        v::OPEN_SK_ID,
        0,
        0,
        0,
        0,
        v::ATTEST_TOKEN,
        2,
        v::OPEN_CP_ROOT,
        v::OPEN_EPOCH,
        0,
        1,
        v::OPEN_PRINCIPAL,
        v::OPEN_ATTEST_SIBLINGS,
        v::OPEN_ATTEST_INDICES,
    );
}
