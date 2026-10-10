// A human vouching for the Provider across from a pool (PROTOCOLO.md Anexo R, 2026-09-29).
//
// A pool has no `sk_id`, so the pair rule of §E.3.14.7 had nobody to be enforced against on its side, and
// the Provider's completed deal against a pool earned no credit. Crediting "once per pool" instead would
// have priced the ladder in pools, which cost a deposit, instead of in humans, which cost a Passport. So a
// human stands in for the pool's side: the deal's Controller proves, with its own account,
//
//   * that the account is registered — some leaf of it is a member of the account tree under `rep_root`.
//     Any version will do: the statement is "this `S` exists", and the tree is append-only;
//   * that `pair_tag` is the pair it forms with the Provider's `S` for THIS deal, blinded by the secret the
//     two picked — the same tag the Provider's `prepare_side` names, which is what the module compares;
//   * that its human is none of the panel's, so the court can seat a panel across from a pool.
//
// What it does NOT do is as deliberate: no nullifier, no new leaf, no cap. The Controller earns nothing —
// the deal's reputation is the pool's — so vouching must not spend its account's version, serialize its
// deals or fill its `inFlight`. Replaying the proof buys nothing either: the tag names one deal.
//
// `verified` (2026-10-01) is the voucher's own flag, published: a vouch stands in a HUMAN for the pool's
// side of the pair rule, so only a verified account's vouch lets the Provider's deal credit. An open account
// may still vouch — the deal records — but the module will not credit across it.
//
// The operator proof of a pool's side (Anexo R, 2026-10-05: a side is an account plus an operator). Three
// more public inputs, all about the pool the vouch is for:
//
//   * `pool_id` — the pool's subject, reduced into the field. A vouch is always some pool's side;
//   * `operator_tag = Poseidon(sk_id, "operator", pool_id)` — the commitment the deal's Controller registered
//     in that pool. The module compares the two, so the human vouching IS the Controller, not some other
//     registered human the Controller found. Unlinkable across pools;
//   * `cp_tag = Poseidon("pool-cp", s_other, pool_id)` — the Provider's stable name in that pool's public
//     counterparty memory, so the pool credits once per distinct Provider, as a peer does. Sound because the
//     pair tag above already forces `s_other` to be the Provider's true `S`.
use pluri_commitments::commitments::{
    account_commitment, hn, leaf_rep, leaf_salt, operator_tag as operator_tag_of, pair_tag as pair_tag_of,
    pool_cp_tag,
};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    deal_id: pub Field,
    rep_root: pub Field,
    pair_tag: pub Field,
    registry_id: pub Field,
    arbiters: pub [Field; 3],
    verified: pub Field,
    pool_id: pub Field,
    operator_tag: pub Field,
    cp_tag: pub Field,
    sk_id: Field,
    s_other: Field,
    pair_secret: Field,
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
        verified,
    );
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");

    // The pair, formed exactly as `prepare_side` forms it on the Provider's side.
    assert(pair_secret != 0, "an unblinded pair tag");
    assert(pair_tag_of(s, s_other, deal_id, pair_secret) == pair_tag, "pair tag mismatch");
    assert(s_other != s, "a deal with yourself is not a counterparty");

    // The pool's side: whose operator this human is, and whom the pool is trading with.
    assert(pool_id != 0, "no pool");
    assert(operator_tag_of(sk_id, pool_id) == operator_tag, "operator tag mismatch");
    assert(pool_cp_tag(s_other, pool_id) == cp_tag, "counterparty tag mismatch");

    // The human who vouches is not on the panel: the account was registered with `hsk == sk_id`.
    let me = hn(sk_id, registry_id);
    for i in 0..3 {
        assert(me != arbiters[i], "a party sits on the panel");
    }
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

/// The pinned registry account vouching for the pinned counterparty in the prepare deal, as the Controller of
/// the sample pool: the same account, deal and pair secret `prepare_side` pins, so the tag it forms is the one
/// the Provider's side names.
fn sample(pair_tag: Field, s_other: Field, pair_secret: Field, arbiters: [Field; 3], root: Field) {
    sample_as(pair_tag, s_other, pair_secret, arbiters, root, 1);
}

fn sample_as(pair_tag: Field, s_other: Field, pair_secret: Field, arbiters: [Field; 3], root: Field, verified: Field) {
    sample_in(
        pair_tag,
        s_other,
        pair_secret,
        arbiters,
        root,
        verified,
        v::PREPARE_POOL_ID,
        v::PREPARE_OPERATOR_TAG,
        v::PREPARE_POOL_CP_TAG,
    );
}

fn sample_in(
    pair_tag: Field,
    s_other: Field,
    pair_secret: Field,
    arbiters: [Field; 3],
    root: Field,
    verified: Field,
    pool_id: Field,
    operator_tag: Field,
    cp_tag: Field,
) {
    main(
        v::PREPARE_DEAL_ID,
        root,
        pair_tag,
        v::PREPARE_REGISTRY_ID,
        arbiters,
        verified,
        pool_id,
        operator_tag,
        cp_tag,
        v::PREPARE_SK_ID,
        s_other,
        pair_secret,
        0,
        0,
        0,
        0,
        0, // leaf0: the genesis leaf
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

/// The pool-side tags of the sample, everything else the sample's.
fn sample_tags(pool_id: Field, operator_tag: Field, cp_tag: Field) {
    sample_in(
        v::PREPARE_PAIR_TAG,
        v::PREPARE_CP_S,
        v::PREPARE_PAIR_SECRET,
        v::PREPARE_ARBITERS,
        v::PREPARE_ROOT,
        1,
        pool_id,
        operator_tag,
        cp_tag,
    );
}

#[test]
fn a_registered_account_vouches_for_its_counterparty() {
    sample(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S, v::PREPARE_PAIR_SECRET, v::PREPARE_ARBITERS, v::PREPARE_ROOT);
}

#[test]
fn a_vouch_without_a_panel_verifies() {
    sample(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S, v::PREPARE_PAIR_SECRET, [0; 3], v::PREPARE_ROOT);
}

/// The tag has to be the one the Provider's side named: another counterparty forms another tag.
#[test(should_fail_with = "pair tag mismatch")]
fn a_vouch_for_someone_else_does_not_name_this_pair() {
    sample(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S + 1, v::PREPARE_PAIR_SECRET, v::PREPARE_ARBITERS, v::PREPARE_ROOT);
}

/// No account behind the vouch, no vouch: a leaf the tree never held.
#[test(should_fail_with = "not a live account leaf")]
fn a_vouch_needs_a_registered_account() {
    sample(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S, v::PREPARE_PAIR_SECRET, v::PREPARE_ARBITERS, v::PREPARE_ROOT + 1);
}

/// An unblinded tag is what a collector of `S` values could test pairs against.
#[test(should_fail_with = "an unblinded pair tag")]
fn a_vouch_blinds_its_tag() {
    sample(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S, 0, v::PREPARE_ARBITERS, v::PREPARE_ROOT);
}

/// The human who vouches is none of the panel's.
#[test(should_fail_with = "a party sits on the panel")]
fn the_voucher_cannot_be_an_arbiter() {
    sample(
        v::PREPARE_PAIR_TAG,
        v::PREPARE_CP_S,
        v::PREPARE_PAIR_SECRET,
        [v::PREPARE_ARBITERS[0], v::PREPARE_OWN_HN, v::PREPARE_ARBITERS[2]],
        v::PREPARE_ROOT,
    );
}

/// The flag is the leaf's: a verified account cannot vouch as an open one, nor the other way round.
#[test(should_fail_with = "not a live account leaf")]
fn a_vouch_names_its_own_flag() {
    sample_as(v::PREPARE_PAIR_TAG, v::PREPARE_CP_S, v::PREPARE_PAIR_SECRET, v::PREPARE_ARBITERS, v::PREPARE_ROOT, 0);
}

/// The operator commitment is this account's in this pool (Anexo R, 2026-10-05): another human's tag, or this
/// human's tag of another pool, is not the one the Controller registered.
#[test(should_fail_with = "operator tag mismatch")]
fn a_vouch_names_its_own_operator_tag() {
    sample_tags(v::PREPARE_POOL_ID, v::PREPARE_OPERATOR_TAG + 1, v::PREPARE_POOL_CP_TAG);
}

#[test(should_fail_with = "operator tag mismatch")]
fn an_operator_tag_does_not_cross_pools() {
    sample_tags(v::PREPARE_POOL_ID + 1, v::PREPARE_OPERATOR_TAG, v::PREPARE_POOL_CP_TAG);
}

/// The counterparty's name in the pool's memory is the Provider's — the one the pair tag forces.
#[test(should_fail_with = "counterparty tag mismatch")]
fn a_vouch_names_the_real_counterparty_in_the_pool() {
    sample_tags(v::PREPARE_POOL_ID, v::PREPARE_OPERATOR_TAG, v::PREPARE_POOL_CP_TAG + 1);
}

/// A vouch is a pool's side: without a pool there is nothing to vouch for.
#[test(should_fail_with = "no pool")]
fn a_vouch_names_a_pool() {
    sample_tags(0, v::PREPARE_OPERATOR_TAG, v::PREPARE_POOL_CP_TAG);
}

/// An open account's vouch (2026-10-01): it proves, and says `verified = 0`, which is what keeps the
/// Provider's deal from crediting.
fn open_vouch(verified: Field) {
    main(
        v::PREPARE_DEAL_ID,
        v::OPEN_ROOT,
        v::OPEN_PAIR_TAG,
        v::PREPARE_REGISTRY_ID,
        v::PREPARE_ARBITERS,
        verified,
        v::PREPARE_POOL_ID,
        v::OPEN_OPERATOR_TAG,
        v::OPEN_POOL_CP_TAG,
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
    );
}

#[test]
fn an_open_account_vouches_as_open() {
    open_vouch(0);
}

#[test(should_fail_with = "not a live account leaf")]
fn an_open_account_cannot_vouch_as_verified() {
    open_vouch(1);
}
