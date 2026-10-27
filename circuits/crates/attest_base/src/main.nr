// The listing attestation of the disclosure layer (PROTOCOLO.md §E.3.15.7, F4 as-built).
// The proof says, in one: "I know `sk_id` behind `handleCommit = Poseidon(sk_id, "handle",
// handleSalt)` — the rotable market pseudonym of §E.3.15.7; the account owns a live leaf
// under `repRoot`, denominated in exactly the public `token`; and the leaf's own stats
// are at least (tier, count) — the claimed LOWER bounds".
//
// Off-chain by design (§E.3.15.9): the consumer verifies with bb (or bb.js later), checks
// `repRoot` against the account tree's live roots (`isKnownRoot` is a public read), and
// cross-checks `decimals` against the served ERC-20. No adapter, no contract: nothing of
// this circuit ever touches the kernel or the trees as a writer.
//
// The claimed bounds are COTAS — understating passes, overstating cannot:
//   * the tier is computed IN-CIRCUIT from the leaf's own stats (§E.3.14.7 via
//     `tiers::score`/`tier_of`), so a penalty already paid can never hide behind a tier
//     it dropped — 12 deals with a +5 penalty is score 10, T2, never the T3 the raw
//     count alone would suggest;
//   * `decimals` is a public input for exactly the reason `prepare_admit` made it one:
//     `UNIT = 250 * 10^decimals` — a private decimals would let a 6-dec leaf claim a
//     2-dec scale and inflate its score by 10^4.
//
// `expiry` is a promise, not a clock: the circuit has no notion of now (that is §E.3.15.7's
// model — the LISTING shows fresh attestations because the consumer's policy prices stale
// ones), so the field is bound into the statement (a public input rides the Honk public
// input binding, exactly like withdraw's `dest`) and the consumer checks it against its
// own clock.
//
// THE RECORD, THE CREDIT AND THE FLAG (2026-10-01, the open accounts). The listing shows the account's
// deals and what it moved from the public RECORD (`rec_count`, `rec_volume`: every completed deal), and its
// tier from the CREDIT (`count`, `volume`: once per counterparty, only between verified accounts) — the
// record is what happened, the tier is what it is worth. `verified` is the leaf's own flag, public and
// exact: a counterparty reading the listing knows whether a proof of humanity stands behind the account,
// and that its record, unlike its tier, is not something a human vouched for.
use pluri_commitments::commitments::{account_commitment, handle_commit as handle_commit_of, leaf_rep, leaf_salt};
use pluri_commitments::merkle::{compute_root, is_member};
use pluri_commitments::tiers;
use pluri_commitments::vectors as v;

fn main(
    handle_commit: pub Field,
    tier: pub Field,
    count: pub Field,
    volume_band: pub Field,
    penalty_band: pub Field,
    expiry: pub Field,
    token: pub Field,
    decimals: pub Field,
    rep_root: pub Field,
    verified: pub Field,
    // The account's secret and the handle's salt (§E.3.15.3: `handleCommit` derives from
    // the same sk_id the leaf does — the pseudonym and the stats are one account).
    sk_id: Field,
    handle_salt: Field,
    // The leaf's private fields (§E.3.15.3 leafRep order).
    count_actual: Field,
    volume: Field,
    penalty_actual: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // The §E.3.14.7 anti-farming state: part of the leaf, so part of the membership proof — and never
    // part of the statement. What a disclosure says about an account is its stats, not who it met.
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
    // The record (2026-10-01): what the count and volume claims are bounds of.
    rec_count: Field,
    rec_volume: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The pseudonym (§E.3.15.7): the listing's handle, rotatable by salt — this proof is
    // the only bridge between the handle and the account behind it.
    assert(handle_commit_of(sk_id, handle_salt) == handle_commit, "handle mismatch");

    // The account behind it: a live leaf of the account tree, of exactly the attested
    // token — the stats are per subject AND token (§E.3.14.7), so a USDC-tier proof can
    // never ride on a PEPE leaf.
    assert(token != 0, "zero token");
    // A leaf without a token has had no deal (LABS-253): the genesis, or an upgrade of it. Every stat of it is
    // zero, so it attests any token honestly — T1, no record, no penalty — and a new account can publish its
    // first listing. A leaf with a token attests only that token.
    if leaf_token != token {
        assert(leaf_token == 0, "leaf token mismatch");
        assert(
            (count_actual == 0) & (volume == 0) & (penalty_actual == 0) & (in_flight == 0) & (rec_count == 0)
                & (rec_volume == 0),
            "a leaf without a token has no stats",
        );
    }
    let s = account_commitment(sk_id);
    let leaf =
        leaf_rep(
            s,
            count_actual,
            volume,
            penalty_actual,
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

    // The tier bound, IN-CIRCUIT: `score` range-checks count/penalty (u64) and volume
    // (u128) itself; the claimed tier must be an ordinal the account's real tier covers.
    let sc = tiers::score(count_actual, volume, penalty_actual, decimals);
    let t_actual: u8 = tiers::tier_of(sc);
    let t_claimed: u8 = tier as u8;
    assert(t_claimed as Field == tier, "tier not an ordinal");
    assert(t_claimed >= 1, "tier zero");
    assert(t_claimed <= 5, "tier too big");
    assert(t_actual >= t_claimed, "claimed tier over the account's");

    // The count bound: the same cotas semantics over the RECORD — every completed deal, credited or not.
    let c_claimed: u128 = count as u128;
    assert(c_claimed as Field == count, "count claim too big");
    let c_actual: u64 = rec_count as u64;
    assert(c_actual as Field == rec_count, "record count too big");
    assert((c_actual as u128) >= c_claimed, "claimed count over the account's");

    // The volume band (§E.3.15.7): what the account has moved, as the protocol's own unit — LOTS of
    // `UNIT = 250·10^decimals`, the same measure the score buys tier with. A lower bound like the two
    // above, and for the same reason: understating what you moved is a weaker true statement.
    //
    // A band and not the figure, because the listing is public: an exact volume is a fingerprint,
    // where "has moved more than 5.000" is what a counterparty actually asks. `decimals` being public
    // is what makes the claim mean anything — with a private scale, dust would buy the top band.
    let v_actual: u8 = tiers::volume_band(rec_volume, decimals);
    let v_claimed: u8 = volume_band as u8;
    assert(v_claimed as Field == volume_band, "volume band not an ordinal");
    assert(v_claimed <= 5, "volume band too big");
    assert(v_actual >= v_claimed, "claimed volume band over the account's");

    // The penalty band, and the ONE claim here whose honest direction is upward. Tier and count
    // are lower bounds — understating is a weaker true statement, so it is allowed. Understating a
    // penalty is not weaker, it is a lie, so the assert runs the other way: a claimed band must
    // cover the account's real one. Overstating stays possible and nobody does it, because it only
    // ever costs the claimant.
    let b_actual: u8 = tiers::penalty_band(penalty_actual);
    let b_claimed: u8 = penalty_band as u8;
    assert(b_claimed as Field == penalty_band, "band not an ordinal");
    assert(b_claimed <= 3, "band too big");
    assert(b_claimed >= b_actual, "claimed band under the account's");

    // The promise's shape: a u64 the consumer can read against its clock. Nothing else —
    // the freshness model of §E.3.15.7 is the consumer's, not the circuit's.
    let e: u64 = expiry as u64;
    assert(e as Field == expiry, "expiry too big");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn attest_base_sample_verifies() {
    // The pinned sample (vectors.json `attest`): the account mid-history — 12 deals,
    // 3 lots, a +5 penalty absorbed — score 10, exactly T2. The claim is the honest
    // exact one: tier 2, count 12.
    assert(v::ATTEST_DEPTH == 32, "account tree depth");
    assert(tiers::tier_of(v::ATTEST_SCORE) == v::ATTEST_TIER as u8, "score/tier pin");
    main(
        v::ATTEST_HANDLE_COMMIT,
        v::ATTEST_TIER,
        v::ATTEST_COUNT_CLAIMED,
        v::ATTEST_VOLUME_BAND,
        v::ATTEST_PENALTY_BAND,
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_VERIFIED,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_VERSION,
        v::ATTEST_CP_ROOT,
        v::ATTEST_EPOCH,
        v::ATTEST_EPOCH_CREDITS,
        v::ATTEST_REC_COUNT,
        v::ATTEST_REC_VOLUME,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test]
fn understating_verifies() {
    // The cotas semantics: claiming LESS than the account has is a valid — if weaker —
    // true statement. T1 and count 0 over the same T2/12 account: the listing may show
    // a floor, never a ceiling someone did not earn.
    main(
        v::ATTEST_HANDLE_COMMIT,
        1, // tier T1 — under the account's T2
        0, // count 0 — under the account's 12
        0, // volume band 0 — under the account's 1, like every other good stat
        3, // penalty band 3 — OVER the account's 1, the one claim whose honest direction is up
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_VERIFIED,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_VERSION,
        v::ATTEST_CP_ROOT,
        v::ATTEST_EPOCH,
        v::ATTEST_EPOCH_CREDITS,
        v::ATTEST_REC_COUNT,
        v::ATTEST_REC_VOLUME,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test]
fn overstating_has_no_witness() {
    // The bound's own arithmetic, pinned straight: the account's real tier is T2
    // (score 10, the penalty-shaped boundary), so a claimed T3 is over it — the
    // comparison `t_actual >= t_claimed` is exactly the equation no witness satisfies.
    // The same holds for count: 13 claims over 12 completed deals are impossible.
    let t_actual: u8 = tiers::tier_of(v::ATTEST_SCORE);
    assert(t_actual == 2, "sample sits at T2");
    let overstated: u8 = (v::ATTEST_TIER + 1) as u8;
    assert(t_actual < overstated, "T3 claim over the T2 account");
    let c_claimed: u128 = (v::ATTEST_REC_COUNT + 1) as u128;
    let c_actual: u128 = v::ATTEST_REC_COUNT as u128;
    assert(c_actual < c_claimed, "count claim over the account's");
}

#[test]
fn the_tier_prices_the_penalty_in() {
    // The atomicity of §E.3.15.5 read from the disclosure side: the penalty entered the
    // leaf through the delta, and the tier the listing can show is computed AFTER it —
    // never around it. The sample sits exactly at T2's floor: score 10 = 12 deals +
    // 3 lots − 5 penalty; the penalty-free stats read 15 (T2 with headroom), and one more
    // Stalemate (+5) past the floor drops the account to T1 (score 5).
    let as_is = tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, v::ATTEST_PENALTY, v::ATTEST_DECIMALS);
    let penalty_free = tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, 0, v::ATTEST_DECIMALS);
    let one_more_stalemate =
        tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, v::ATTEST_PENALTY + 5, v::ATTEST_DECIMALS);
    assert(as_is == v::ATTEST_SCORE, "score pin");
    assert(as_is == 10, "the sample sits at T2's floor");
    assert(penalty_free == 15, "penalty-free stats read 15");
    assert(tiers::tier_of(as_is) == 2, "T2 with the penalty priced in");
    assert(tiers::tier_of(penalty_free) == 2, "T2 with headroom without it");
    assert(tiers::tier_of(one_more_stalemate) == 1, "one more stalemate past the floor drops to T1");
}

#[test(should_fail_with = "claimed band under the account's")]
fn understating_the_penalty_has_no_proof() {
    // The asymmetry that makes the listing worth reading. Tier and count may be understated,
    // because a weaker true statement is still true. A penalty band may not: understating what
    // went wrong is not a weaker claim, it is a false one. The sample absorbed a +5, so band 1 —
    // claiming 0 is the lie the circuit refuses.
    main(
        v::ATTEST_HANDLE_COMMIT,
        v::ATTEST_TIER,
        v::ATTEST_COUNT_CLAIMED,
        v::ATTEST_VOLUME_BAND,
        0, // clean — against an account that is not
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_VERIFIED,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_VERSION,
        v::ATTEST_CP_ROOT,
        v::ATTEST_EPOCH,
        v::ATTEST_EPOCH_CREDITS,
        v::ATTEST_REC_COUNT,
        v::ATTEST_REC_VOLUME,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test(should_fail_with = "claimed volume band over the account's")]
fn overstating_the_volume_has_no_proof() {
    // The good stats' own direction, on the new field: the sample moved 3 lots (750 of the 6-dec
    // token) which is band 1, so claiming band 2 — "more than 1.000 moved" — has no witness. This is
    // the claim the listing exists to make trustworthy: volume is what a counterparty reads as skin.
    main(
        v::ATTEST_HANDLE_COMMIT,
        v::ATTEST_TIER,
        v::ATTEST_COUNT_CLAIMED,
        v::ATTEST_VOLUME_BAND + 1,
        v::ATTEST_PENALTY_BAND,
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_VERIFIED,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_VERSION,
        v::ATTEST_CP_ROOT,
        v::ATTEST_EPOCH,
        v::ATTEST_EPOCH_CREDITS,
        v::ATTEST_REC_COUNT,
        v::ATTEST_REC_VOLUME,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test]
fn the_listing_shows_floors_and_one_ceiling() {
    // The shape of the whole statement, in one place. Three of the four aggregates are FLOORS the
    // account is at least at (tier, count, volume band) and one is a CEILING it is at most at
    // (penalty band). That asymmetry is the listing: everything good can only be understated,
    // everything bad can only be overstated, and both directions are the same word — honest.
    assert(tiers::tier_of(v::ATTEST_SCORE) as Field == v::ATTEST_TIER, "tier floor");
    assert(v::ATTEST_COUNT_CLAIMED == v::ATTEST_REC_COUNT, "count floor, claimed exactly here");
    assert(
        tiers::volume_band(v::ATTEST_REC_VOLUME, v::ATTEST_DECIMALS) as Field == v::ATTEST_VOLUME_BAND,
        "volume floor",
    );
    assert(tiers::penalty_band(v::ATTEST_PENALTY) as Field == v::ATTEST_PENALTY_BAND, "penalty ceiling");
}

#[test]
fn the_record_can_say_more_than_the_tier() {
    // The sample recorded more deals than it was credited for (repeat counterparties): the listing's count
    // is the record's, and still the tier is the credit's — T2, not what fifteen deals would buy.
    assert((v::ATTEST_REC_COUNT as u64) > (v::ATTEST_COUNT as u64), "the sample tells the two apart");
    assert(v::ATTEST_COUNT_CLAIMED == v::ATTEST_REC_COUNT, "the listing claims the record");
    let as_record = tiers::score(v::ATTEST_REC_COUNT, v::ATTEST_REC_VOLUME, v::ATTEST_PENALTY, v::ATTEST_DECIMALS);
    assert((as_record as u64) > (v::ATTEST_SCORE as u64), "the record alone would score higher");
    assert(v::ATTEST_TIER == 2, "the tier is the credit's");
}

/// The open account's listing (vectors `open`): one completed deal in the record, nothing credited, no
/// Passport. `verified` and the claimed bounds vary.
fn open_attest(tier: Field, count: Field, verified: Field) {
    main(
        handle_commit_of(v::OPEN_SK_ID, v::ATTEST_HANDLE_SALT),
        tier,
        count,
        0,
        0,
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::OPEN_ATTEST_ROOT,
        verified,
        v::OPEN_SK_ID,
        v::ATTEST_HANDLE_SALT,
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

#[test]
fn an_open_account_lists_its_record_and_says_it_is_open() {
    open_attest(1, 1, 0);
}

#[test(should_fail_with = "not a live account leaf")]
fn an_open_account_cannot_list_as_verified() {
    open_attest(1, 1, 1);
}

#[test(should_fail_with = "claimed tier over the account's")]
fn an_open_account_stays_at_t1() {
    open_attest(2, 1, 0);
}

/// A new account (LABS-253): its genesis leaf has no token and every stat zero. `count` is the leaf's credit,
/// `rec` its record — non-zero only to show that a leaf without a token cannot carry stats.
fn fresh_attest(verified: Field, tier: Field, claimed: Field, count: Field, rec: Field) {
    let sk_id = v::OPEN_SK_ID;
    let leaf = leaf_rep(account_commitment(sk_id), count, 0, 0, 0, 0, leaf_salt(sk_id, 0), 0, v::OPEN_CP_ROOT, 0, 0, rec, 0, verified);
    let siblings = [0; 32];
    let indices = [0; 32];
    main(
        handle_commit_of(sk_id, v::ATTEST_HANDLE_SALT),
        tier,
        claimed,
        0,
        0,
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        compute_root::<32>(leaf, siblings, indices),
        verified,
        sk_id,
        v::ATTEST_HANDLE_SALT,
        count,
        0,
        0,
        0,
        0,
        0,
        v::OPEN_CP_ROOT,
        0,
        0,
        rec,
        0,
        siblings,
        indices,
    );
}

#[test]
fn a_new_account_attests_any_token_with_nothing_in_it() {
    fresh_attest(1, 1, 0, 0, 0);
    fresh_attest(0, 1, 0, 0, 0);
}

#[test(should_fail_with = "claimed count over the account's")]
fn a_new_account_claims_no_record() {
    fresh_attest(1, 1, 1, 0, 0);
}

#[test(should_fail_with = "a leaf without a token has no stats")]
fn a_leaf_without_a_token_carries_no_stats() {
    fresh_attest(1, 1, 1, 0, 1);
}
