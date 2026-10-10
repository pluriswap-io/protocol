// The passport side of the activation bundle (PROTOCOLO.md §E.3.15.4, V2 as-built). The
// proof says, in one: "I know `sk_id` such that `dealSubject = Poseidon(sk_id, dealId)`,
// and an account leaf of mine — `leafRep(S, ...)` with `S = Poseidon(sk_id)` — sits in a
// live tree under `repRoot`". The wallet's EIP-712 signature (checked on-chain by
// `PrivatePassport.prepare`) pins that subject under the wallet; the leaf's stats are
// witnesses because the passport gates on registration, never on capacity — the
// admission side (prepare_admit) is the proof that computes tiers.
//
// `dealId` stays private: the deal pseudonym is the only thing the kernel ever sees, and
// the binding `dealSubject = Poseidon(sk_id, dealId)` is what a compositor cannot forge.
use pluri_commitments::commitments::{account_commitment, deal_subject, leaf_rep, leaf_salt};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    subject: pub Field,
    rep_root: pub Field,
    sk_id: Field,
    deal_id: Field,
    // The account's current leaf — all fields private witnesses; the passport gates on
    // registration ("S in a live leaf"), not on the stats.
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // The anti-farming state rides through untouched: the passport proves registration, never stats.
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
    rec_count: Field,
    rec_volume: Field,
    verified: Field,
    // Depth-32 account-tree membership witness (§E.3.15.3).
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The per-deal pseudonym (§E.3.15.3): dealSubject = PoseidonT3(sk_id, dealId).
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    let s = account_commitment(sk_id);
    // The leaf's salt is derived, like everywhere else the account leaf is built (2026-09-23:
    // this was the last circuit still taking it as a free witness). Membership alone already
    // forced the honest value — nothing else is in the tree — but a rule applied in five of six
    // places is the worst kind of rule to have.
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
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn prepare_passport_sample_verifies() {
    // The pinned sample (vectors.json `prepare`): the registered genesis leaf0 of the
    // registry sample account, against the depth-32 account-tree root.
    assert(v::PREPARE_DEPTH == 32, "account tree depth");
    main(
        v::PREPARE_DEAL_SUBJECT,
        v::PREPARE_ROOT,
        v::PREPARE_SK_ID,
        v::PREPARE_DEAL_ID,
        0,
        0,
        0,
        0,
        0, // leaf0's token is zero: nothing has happened in any token yet
        0, // version zero — and the salt is derived from it, no longer passed
        v::PREPARE_CP_ROOT, // the genesis counterparty tree: empty
        0,
        0,
        0, // an empty record
        0,
        1, // a verified account

        v::PREPARE_SIBLINGS,
        v::PREPARE_INDICES,
    );
}
