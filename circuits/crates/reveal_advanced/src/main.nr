// The profile reveal of the disclosure layer (PROTOCOLO.md §E.3.15.7, F4 as-built).
// attest_base shows the listing its bounds; this shows the requester its CHOSEN FIELDS
// exactly: `out = mask * field` — bit0 volume, bit1 penalty — so "campos elegidos" is
// arithmetic, not control flow (the whole-consumption mask pattern of withdraw). A
// hidden field's output is zero; a shown field's output is the leaf's own value.
//
// `requester` is the §E.3.15.7 optional bind: the pubkey hash of the one requester this
// profile was minted for — zero when the reveal is public under the handle. It rides
// the public-input binding (the same wire withdraw's `dest` uses): a proof minted for
// requester A cannot be repurposed as B's, and the tamper test of the verify lib pins
// that empirically.
//
// Off-chain like attest_base: the requester verifies with bb, the handle is the
// capability (no handle, no query), and the freshness anchor is the root's liveness at
// delivery — §E.3.15.7 gives reveal_advanced no `expiry` by design; the requester's
// receipt is the timestamp.
//
// The bounds below are bounds FOR THE MASK (the leaf_rep hashes any Field, but the
// mask multiplies — the outputs must stay canonical u128s the consumer reads).
use pluri_commitments::commitments::{account_commitment, handle_commit as handle_commit_of, leaf_rep, leaf_salt};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    handle_commit: pub Field,
    fields_mask: pub Field,
    out_count: pub Field,
    out_volume: pub Field,
    out_penalty: pub Field,
    requester: pub Field,
    token: pub Field,
    rep_root: pub Field,
    // The account's secret and the handle's salt — the same pair attest_base binds.
    sk_id: Field,
    handle_salt: Field,
    // The leaf's private fields (§E.3.15.3 leafRep order).
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // The §E.3.14.7 anti-farming state: part of the leaf, so part of the membership proof — and never
    // part of the statement. What a disclosure says about an account is its stats, not who it met.
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
    // The public record and the flag (2026-10-01). The profile reveals the RECORD — every completed deal,
    // the same counter the listing shows — while `count`/`volume` above are the credit, which the tier
    // already speaks for.
    rec_count: Field,
    rec_volume: Field,
    verified: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The mask: bit0 count, bit1 volume. The PENALTY is not in it — §E.3.15.7 makes it
    // mandatory, because a reveal can be published under a handle without a base
    // attestation, and leaving the penalty optional here would keep the escape hatch the
    // base attestation was changed to close.
    let m: u8 = fields_mask as u8;
    assert(m as Field == fields_mask, "mask too big");
    assert(m < 4, "unknown fields");
    let mc: Field = (m & 1) as Field;
    let mv: Field = ((m >> 1) & 1) as Field;

    // The pseudonym + the live leaf, exactly as attest_base: same account, same tree,
    // same token binding — the profile is the listing's account, seen closer.
    assert(handle_commit_of(sk_id, handle_salt) == handle_commit, "handle mismatch");
    assert(token != 0, "zero token");
    assert(leaf_token == token, "leaf token mismatch");
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

    // Bounds for the masked arithmetic.
    let cnt: u128 = rec_count as u128;
    assert(cnt as Field == rec_count, "count too big");
    let vol: u128 = rec_volume as u128;
    assert(vol as Field == rec_volume, "volume too big");
    let pen: u128 = penalty as u128;
    assert(pen as Field == penalty, "penalty too big");

    // The exact reveal: the selector computes the output — the field when chosen, zero
    // when hidden. No branch: the shape stays inside what the pinned bb pipeline accepts.
    assert(out_count == mc * rec_count, "count mask mismatch");
    assert(out_volume == mv * rec_volume, "volume mask mismatch");
    // Raw and unconditional: the profile always states what went wrong.
    assert(out_penalty == penalty, "penalty must be revealed in full");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn reveal_sample_verifies() {
    // The pinned sample (vectors.json `reveal`): the profile of the attest account
    // (§E.3.15.7's advanced stats, §E.3.15.3's leaf order) — both fields chosen (mask 0b11),
    // minted for the pinned requester, against the same insert-time root as the listing
    // attestation: one account state, two views.
    assert(v::REVEAL_FIELDS_MASK == 3, "both fields chosen");
    main(
        v::REVEAL_HANDLE_COMMIT,
        v::REVEAL_FIELDS_MASK,
        v::REVEAL_OUT_COUNT,
        v::REVEAL_OUT_VOLUME,
        v::REVEAL_OUT_PENALTY,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_CP_ROOT,
        v::REVEAL_EPOCH,
        v::REVEAL_EPOCH_CREDITS,
        v::REVEAL_REC_COUNT,
        v::REVEAL_REC_VOLUME,
        1,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}

#[test]
fn the_mask_covers_count_and_volume_only() {
    // "Campos elegidos" is now count and volume. The penalty is outside the mask: a profile
    // always states what went wrong, whatever else it chooses to withhold.
    let cnt: u128 = v::REVEAL_REC_COUNT as u128;
    let vol: u128 = v::REVEAL_REC_VOLUME as u128;
    let pen: Field = v::REVEAL_PENALTY;
    // mask 0b01: count shown, volume hidden -- and the penalty shown regardless.
    main(
        v::REVEAL_HANDLE_COMMIT,
        1,
        cnt as Field,
        0,
        pen,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_CP_ROOT,
        v::REVEAL_EPOCH,
        v::REVEAL_EPOCH_CREDITS,
        v::REVEAL_REC_COUNT,
        v::REVEAL_REC_VOLUME,
        1,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
    // mask 0b00: neither chosen field shown, and STILL the penalty. A profile that reveals
    // nothing else is a true if empty statement; one that hides its penalty is not available.
    main(
        v::REVEAL_HANDLE_COMMIT,
        0,
        0,
        0,
        pen,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_CP_ROOT,
        v::REVEAL_EPOCH,
        v::REVEAL_EPOCH_CREDITS,
        v::REVEAL_REC_COUNT,
        v::REVEAL_REC_VOLUME,
        1,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}

#[test(should_fail_with = "penalty must be revealed in full")]
fn a_profile_cannot_hide_its_penalty() {
    // The point of the change (§E.3.15.7). A reveal can be published under a handle with no base
    // attestation behind it, so if the penalty were optional here the listing's mandatory band
    // would have an open back door. Claiming zero against a penalised account has no proof.
    main(
        v::REVEAL_HANDLE_COMMIT,
        0,
        0,
        0,
        0,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_CP_ROOT,
        v::REVEAL_EPOCH,
        v::REVEAL_EPOCH_CREDITS,
        v::REVEAL_REC_COUNT,
        v::REVEAL_REC_VOLUME,
        1,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}

#[test]
fn the_outputs_are_the_exact_fields() {
    // The mask's own arithmetic, pinned straight against the generated constants: the
    // shown outputs commit to exactly the leaf's volume and penalty — the reveal is
    // exact, never a bound (§E.3.15.7's difference from attest_base).
    let shown_volume: Field = v::REVEAL_OUT_VOLUME;
    let shown_penalty: Field = v::REVEAL_OUT_PENALTY;
    assert(shown_volume == v::REVEAL_REC_VOLUME, "volume revealed exactly");
    assert(v::REVEAL_OUT_COUNT == v::REVEAL_REC_COUNT, "count revealed exactly");
    assert(shown_penalty == v::REVEAL_PENALTY, "penalty revealed exactly");
}

#[test(should_fail_with = "count mask mismatch")]
fn the_profile_count_is_the_record_not_the_credit() {
    // The sample has more recorded deals than credited ones (a repeat counterparty, 2026-10-01). The
    // profile's count is the record — the listing's counter — so naming the credit instead has no proof.
    assert(v::REVEAL_COUNT != v::REVEAL_REC_COUNT, "the sample tells the two apart");
    main(
        v::REVEAL_HANDLE_COMMIT,
        1,
        v::REVEAL_COUNT,
        0,
        v::REVEAL_PENALTY,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_CP_ROOT,
        v::REVEAL_EPOCH,
        v::REVEAL_EPOCH_CREDITS,
        v::REVEAL_REC_COUNT,
        v::REVEAL_REC_VOLUME,
        1,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}
