// The account circuit of the register bundle (PROTOCOLO.md §E.3.15.9, V1 as-built): the
// account-leaf side of "one human, one account". It proves the binding the humanity circuit
// cannot express on its own: that the leaf being inserted belongs to the same secret behind
// the burned `hn`.
//
// The link is `hn`: proving it requires knowing `hsk`, so the account being registered belongs to
// the enrolled human. The leaf's salt is DERIVED from `sk_id` instead (§E.3.15.3) — it used to be
// `hsk`, which tied recovery of the account to a second secret for no gain, since the `hn` assert
// already carries the binding. No membership is re-proven here: the bundle order is
// enforced on-chain (passport.register first — the hn is only trusted once the passport has
// burned it against its own membership proof), and the identical public `hn` across both
// proofs cannot be satisfied twice with different registry domains without breaking Poseidon.
// The adapter still amplifies `registry_id` with its own read of the served registry, so a
// proof naming a foreign domain fails closed before the Honk verifier is ever reached.
//
// Initial leaf (§E.3.15.9): all counters zero (count, volume, penalty, inFlight, and the public
// record), token zero (nothing has happened in any token yet), version zero, salt derived from sk_id.
//
// TWO SHAPES, one circuit (2026-10-01, the open accounts). `verified == 1` is the register bundle
// above: the leaf is bound to the human behind `h_n`, and the leaf says so. `verified == 0` is an
// account without a Passport: no human, so no nullifier — `h_n` is zero and `hsk` is not looked at —
// and a leaf that says so forever (an open account becomes verified only through `upgrade_account`,
// which proves the humanity it lacked). What both shapes share is the part an open account cannot be
// trusted to skip: the genesis is zero, so nobody registers into the tree with a record they never
// earned. Masked rather than branched, for the codegen reason circuits/README.md records.
use pluri_commitments::commitments::{account_commitment, hn, leaf_rep, leaf_salt};
use pluri_commitments::merkle;
use pluri_commitments::vectors as v;

fn main(
    h_n: pub Field,
    leaf0: pub Field,
    registry_id: pub Field,
    verified: pub Field,
    hsk: Field,
    sk_id: Field,
) {
    assert(verified * (1 - verified) == 0, "verified is a bit");
    // The same nullifier the humanity circuit derived — the bundle's binding — when there is a human.
    assert(verified * (hn(hsk, registry_id) - h_n) == 0, "hn mismatch");
    // And none when there is not: an open account names no human, so it cannot spend somebody's.
    assert((1 - verified) * h_n == 0, "an open account names no human");
    // The account: S = Poseidon(sk_id), never on-chain in the clear.
    let s = account_commitment(sk_id);
    // The initial leaf, salted by DERIVATION from the account secret (§E.3.15.3). It used to be
    // salted with `hsk`, which tied recovery of the account to a SECOND secret: you needed both
    // the registry secret and the account secret to rebuild version zero. The human-to-account
    // binding does not depend on it — the `hn` assert above already requires knowing `hsk` — so
    // deriving from `sk_id` loses nothing and makes `sk_id` alone enough to recover.
    // The genesis leaf: every counter zero, no token yet, the derived salt — and an EMPTY
    // counterparty tree (§E.3.14.7): a new account has met nobody, so its first deal with anyone at
    // all is creditable. The rate window starts at zero too.
    assert(
        leaf_rep(
            s,
            0,
            0,
            0,
            0,
            0,
            leaf_salt(sk_id, 0),
            0,
            merkle::empty_root::<32>(),
            0,
            0,
            0,
            0,
            verified,
        )
            == leaf0,
        "leaf0 mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn hn_matches_vectors() {
    assert(hn(v::REGISTRY_HSK, v::REGISTRY_ID) == v::REGISTRY_SAMPLE_HN, "sample hn");
}

#[test]
fn leaf0_matches_vectors() {
    let s = account_commitment(v::REGISTRY_SAMPLE_SK_ID);
    assert(s == v::REGISTRY_SAMPLE_S, "sample S");
    assert(
        leaf_rep(
            s,
            0,
            0,
            0,
            0,
            0,
            leaf_salt(v::REGISTRY_SAMPLE_SK_ID, 0),
            0,
            merkle::empty_root::<32>(),
            0,
            0,
            0,
            0,
            1,
        )
            == v::REGISTRY_SAMPLE_LEAF0,
        "sample leaf0",
    );
}

/// The pinned register bundle, as the prover runs it.
#[test]
fn a_verified_registration_verifies() {
    main(v::REGISTRY_SAMPLE_HN, v::REGISTRY_SAMPLE_LEAF0, v::REGISTRY_ID, 1, v::REGISTRY_HSK, v::REGISTRY_SAMPLE_SK_ID);
}

/// An open account: no human, no nullifier, and a genesis that says `verified = 0`.
#[test]
fn an_open_registration_verifies() {
    main(0, v::OPEN_LEAF0, v::REGISTRY_ID, 0, 0, v::OPEN_SK_ID);
}

/// The open shape cannot insert a verified genesis: the leaf commits to its own flag, so a leaf that says
/// `verified = 1` needs the human the open shape does not name.
#[test(should_fail_with = "leaf0 mismatch")]
fn an_open_registration_cannot_insert_a_verified_leaf() {
    main(0, v::REGISTRY_SAMPLE_LEAF0, v::REGISTRY_ID, 0, 0, v::REGISTRY_SAMPLE_SK_ID);
}

/// And the verified shape cannot be claimed without one.
#[test(should_fail_with = "hn mismatch")]
fn a_verified_genesis_needs_a_human() {
    main(0, v::OPEN_LEAF0, v::REGISTRY_ID, 1, 0, v::OPEN_SK_ID);
}

/// Nor can it spend a human's nullifier on the way in.
#[test(should_fail_with = "an open account names no human")]
fn an_open_account_names_no_human() {
    main(v::REGISTRY_SAMPLE_HN, v::OPEN_LEAF0, v::REGISTRY_ID, 0, v::REGISTRY_HSK, v::OPEN_SK_ID);
}

/// A verified registration still has to be the human it names.
#[test(should_fail_with = "hn mismatch")]
fn a_verified_registration_needs_its_human() {
    main(v::REGISTRY_SAMPLE_HN, v::REGISTRY_SAMPLE_LEAF0, v::REGISTRY_ID, 1, v::REGISTRY_HSK + 1, v::REGISTRY_SAMPLE_SK_ID);
}

/// The flag is a bit: there is no third kind of account.
#[test(should_fail_with = "verified is a bit")]
fn the_flag_is_a_bit() {
    main(0, v::OPEN_LEAF0, v::REGISTRY_ID, 2, 0, v::OPEN_SK_ID);
}
