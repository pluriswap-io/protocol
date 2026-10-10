// The admission tiers of PROTOCOLO.md §E.3.14.7 — the Noir twin of the table the on-chain
// reputation reads (`Reputation.score` / `Reputation._capTokens`) and the JS twin of the
// generator (`circuits/js/lib/tiers.ts`) computes. The circuit proves the tier IN-CIRCUIT
// (§E.3.15.4): the cap of `inFlight + principal <= cap` comes from these functions over the
// leaf's own stats, never from a trusted on-chain read.
//
//   score = satSub(count + volume / UNIT, penalty),   UNIT = 250 * 10^decimals
//
// Integer semantics everywhere: the volume's division into lots TRUNCATES (Field `/` is
// multiplicative, so the division happens in u128 after range asserts), the penalty's
// subtraction SATURATES at zero.

use crate::vectors;

/// 10^`d`, computed as a bounded loop over a public input: the scale is derived, never
/// trusted. The bound (32) keeps the honest computation a fixed 32 steps; anything past
/// it has no proof at all.
///
/// This nargo forbids relational operators on Field (equality only), so every range
/// check goes through the cast-round-trip idiom: cast down to an integer, cast back up,
/// assert equality — a truncated cast cannot survive the round trip.
pub fn pow10(d: Field) -> Field {
    let d32: u32 = d as u32;
    assert(d32 as Field == d, "decimals not an integer");
    assert(d32 < 32, "decimals out of range");
    let mut acc: Field = 1;
    for i in 0..32 {
        let level: u32 = i as u32;
        acc = if level < d32 { acc * 10 } else { acc };
    }
    acc
}

/// The §E.3.14.7 score of an account leaf: `satSub(count + volume/UNIT, penalty)` with
/// `UNIT = 250 * 10^decimals` — one lot is a full-cap T1 deal, so five clean T1 deals
/// buy T2, and no single trade can skip tiers.
///
/// Bounds: count and penalty are success/penalty counters (2^64 is generous beyond
/// argument); volume is raw token units under 2^128 (1.7e38 raw — 1.7e20 full tokens at
/// 18 decimals). Every bound only rejects: a witness too big to vouch for has no proof,
/// which is the fail-closed direction.
pub fn score(count: Field, volume: Field, penalty: Field, decimals: Field) -> Field {
    let c64: u64 = count as u64;
    assert(c64 as Field == count, "count too big");
    let p64: u64 = penalty as u64;
    assert(p64 as Field == penalty, "penalty too big");
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let unit = 250 * pow10(decimals);
    let unit_u: u128 = unit as u128;
    // lots <= vol/250 < 2^121, count < 2^64: the u128 sum cannot overflow.
    let lots: u128 = vol / unit_u;
    let base: u128 = (c64 as u128) + lots;
    let p: u128 = p64 as u128;
    let sc: u128 = if p > base { 0 } else { base - p };
    sc as Field
}

/// T5's "sin límite" as a raw bound: 2^128-1. Any provable `inFlight + principal` (both
/// are cast-checked below 2^64) fits under it, so ONE unconditional comparison serves
/// every tier — no `unbounded` branch in the circuit at all. The on-chain twin encodes
/// the same idea with `type(uint256).max` (`Reputation._capTokens`).
///
/// The shape is deliberate: a negated-guard statement-if around the bound check makes
/// bb's optimized EVM verifier codegen reject its own valid proofs (bisected: the same
/// circuit with an unconditional check verifies on-chain, the guarded one does not — see
/// circuits/README.md). The unconditional shape is the one this protocol uses.
pub global T5_SENTINEL: Field = 340282366920938463463374607431768211455; // 2^128 - 1

/// The cap a score buys, in raw token units of the tier's column: T5 the sentinel, the
/// other tiers their units scaled by the token's decimals.
pub fn cap_raw(sc: Field, with_bond: bool, decimals: Field) -> Field {
    let s: u128 = sc as u128;
    assert(s as Field == sc, "score too big");
    let units = cap_units(s, with_bond);
    if units == 0 {
        T5_SENTINEL
    } else {
        units * pow10(decimals)
    }
}

/// 0 means unbounded (the sentinel takes over in `cap_raw`); otherwise the tier's cap in whole
/// tokens of the column.
///
/// T5's unbounded column is the BOND one (2026-09-23). It used to be both, which put the protocol's
/// only unlimited exposure exactly where the money is and with no skin behind it: 21 deals bought a
/// cap of infinity and a bond of nothing. Now the ladder tops out at 5.000 without bond — a step
/// above T4 and equal to T4's bond column, so climbing still pays — and unlimited requires a live
/// lock, which at §E.3.14.5's 10% means any exposure is always 10% backed by its own holder.
fn cap_units(sc: u128, with_bond: bool) -> Field {
    if sc >= 100 {
        if with_bond { 0 } else { 5000 }
    } else if sc >= 50 {
        if with_bond { 5000 } else { 2000 }
    } else if sc >= 25 {
        if with_bond { 1500 } else { 1000 }
    } else if sc >= 10 {
        if with_bond { 700 } else { 500 }
    } else {
        if with_bond { 400 } else { 250 }
    }
}

/// The tier ordinal a score buys (1..5) — the disclosure layer's (F4) reading of the same
/// ladder: `attest_base`'s claimed tier is a LOWER bound of this. `cap_units` encodes T5
/// as 0; here the ordinal is explicit — the attestation's public semantics is the tier,
/// not the cap. Same thresholds, same `u128` ordered comparison (no relational ops on
/// Field in this nargo).
pub fn tier_of(sc: Field) -> u8 {
    let s: u128 = sc as u128;
    assert(s as Field == sc, "score too big");
    if s >= 100 {
        5
    } else if s >= 50 {
        4
    } else if s >= 25 {
        3
    } else if s >= 10 {
        2
    } else {
        1
    }
}

/// The volume BAND of §E.3.15.7: the other aggregate a public listing carries, where the exact figure
/// belongs to the advanced reveal.
///
/// The cuts are LOTS, not round numbers of someone's favourite token: a lot is `UNIT = 250·10^decimals`,
/// the same unit `score` buys tier with, so the band is denominated in the protocol's own measure and
/// reads correctly in any token and any decimals. In whole tokens the floors are 250, 1.000, 5.000,
/// 20.000 and 100.000 — which is what a listing shows, since `token` and `decimals` are public too:
///
///   0  under one lot   nothing meaningful moved yet
///   1  1..3            250+
///   2  4..19           1.000+
///   3  20..79          5.000+
///   4  80..399         20.000+
///   5  400+            100.000+
///
/// It is a LOWER bound, like tier and count and unlike the penalty band: understating what you moved
/// is a weaker true statement, overstating it has no witness. A band rather than the figure because a
/// public listing is read by everyone and an exact volume is a fingerprint; a counterparty asking "is
/// this person moving hundreds or hundreds of thousands" gets the answer, and whoever wants the exact
/// number asks for the profile.
pub fn volume_band(volume: Field, decimals: Field) -> u8 {
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let unit: u128 = (250 * pow10(decimals)) as u128;
    let lots: u128 = vol / unit;
    if lots >= 400 {
        5
    } else if lots >= 80 {
        4
    } else if lots >= 20 {
        3
    } else if lots >= 4 {
        2
    } else if lots >= 1 {
        1
    } else {
        0
    }
}

/// The penalty BAND of §E.3.15.7: the aggregate a public listing carries, where the raw number
/// belongs to the advanced reveal.
///
/// A listing is read by everyone, so a raw counter is a fingerprint — "47 deals, 12,350 of volume"
/// identifies a person more than it informs a counterparty. A band informs and does not identify.
///
/// The cuts are events, not round numbers. A tribunal's stalemate, an abandoned dispute or a Provider's
/// no-show is +5, a deadlock (a dispute nobody settled, in a deal with no tribunal) is +10 and an
/// arbitration loss is +15 (§E.3.14.7), so:
///
///   0  clean          nothing has ever gone wrong
///   1  1..5           one stalemate, one abandoned dispute or one no-show
///   2  6..15          several of those, one deadlock, or one proven loss at a tribunal
///   3  16+            more than one proven loss
///
/// The band is what makes the tier readable. A tier nets the penalty into the score, so a punished
/// T2 falls to T1 and becomes indistinguishable from an honest newcomer — which is exactly the
/// distinction a counterparty most needs. The band restores it without publishing the counter.
pub fn penalty_band(penalty: Field) -> u8 {
    let p: u128 = penalty as u128;
    assert(p as Field == penalty, "penalty too big");
    if p >= 16 {
        3
    } else if p >= 6 {
        2
    } else if p >= 1 {
        1
    } else {
        0
    }
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn pow10_matches() {
    assert(pow10(0) == 1, "10^0");
    assert(pow10(1) == 10, "10^1");
    assert(pow10(6) == 1000000, "10^6");
    assert(pow10(18) == 1000000000000000000, "10^18");
}

#[test]
fn tier_ordinals_match_the_ladder() {
    // §E.3.14.7's ladder as ordinals: the five thresholds, boundary-anchored on both sides.
    assert(tier_of(0) == 1, "T1 floor");
    assert(tier_of(9) == 1, "just under T2");
    assert(tier_of(10) == 2, "T2 boundary");
    assert(tier_of(24) == 2, "just under T3");
    assert(tier_of(25) == 3, "T3 boundary");
    assert(tier_of(49) == 3, "just under T4");
    assert(tier_of(50) == 4, "T4 boundary");
    assert(tier_of(99) == 4, "just under T5");
    assert(tier_of(100) == 5, "T5 boundary");
}

#[test]
fn only_the_bond_column_is_unbounded() {
    // The 2026-09-23 change, anchored: T5 without bond tops at 5.000 (T4's bond column — climbing
    // still pays), and the protocol's only unlimited exposure is the one with a live lock behind it.
    assert(cap_raw(100, false, 6) == 5000000000, "T5 base is finite");
    assert(cap_raw(100, true, 6) == T5_SENTINEL, "T5 with bond is unbounded");
    assert(cap_raw(99, false, 6) == 2000000000, "T4 base unchanged");
    assert(cap_raw(99, true, 6) == 5000000000, "T4 bond unchanged");
}

#[test]
fn tiers_match_vectors() {
    for i in 0..vectors::TIER_COUNT {
        let sc = score(
            vectors::TIER_COUNTS[i],
            vectors::TIER_VOLUMES[i],
            vectors::TIER_PENALTIES[i],
            vectors::TIER_DECIMALS[i],
        );
        assert(sc == vectors::TIER_SCORES[i], "score mismatch");
        // The vectors carry T5 as (cap 0, unbounded true); the circuit encodes it as the
        // sentinel. The mapping is asserted, not assumed.
        let base_expected =
            if vectors::TIER_UNBOUNDED_BASE[i] { T5_SENTINEL } else { vectors::TIER_CAPS_BASE[i] };
        let bond_expected =
            if vectors::TIER_UNBOUNDED_BOND[i] { T5_SENTINEL } else { vectors::TIER_CAPS_BOND[i] };
        assert(cap_raw(sc, false, vectors::TIER_DECIMALS[i]) == base_expected, "base cap mismatch");
        assert(cap_raw(sc, true, vectors::TIER_DECIMALS[i]) == bond_expected, "bond cap mismatch");
    }
}

#[test]
fn penalty_bands_match_the_cuts() {
    // §E.3.15.7's aggregate, boundary-anchored on both sides of every cut. The bands are events:
    // 0 clean, 1 one stalemate or abandoned dispute (+5), 2 several of those or one proven loss
    // (+15), 3 more than one loss.
    assert(penalty_band(0) == 0, "clean");
    assert(penalty_band(1) == 1, "the first point");
    assert(penalty_band(5) == 1, "one stalemate");
    assert(penalty_band(6) == 2, "more than one");
    assert(penalty_band(15) == 2, "one arbitration loss");
    assert(penalty_band(16) == 3, "a loss plus a stalemate");
}

#[test]
fn penalty_bands_match_vectors() {
    // The JS twin's own rows (`tiers.penaltyBand`), so the listing a consumer reads and the
    // profile a generator mints cannot drift apart. A band is not in the score, so these rows
    // pin it independently of the ladder above.
    for i in 0..vectors::TIER_COUNT {
        let b = penalty_band(vectors::TIER_PENALTIES[i]);
        assert(b as Field == vectors::TIER_BANDS[i], "band mismatch");
    }
}

#[test]
fn volume_bands_match_the_lots() {
    // The cuts as LOTS, anchored on both sides, at 6 decimals (a lot = 250_000_000 raw).
    let unit: Field = 250000000;
    assert(volume_band(0, 6) == 0, "nothing moved");
    assert(volume_band(unit - 1, 6) == 0, "just under one lot");
    assert(volume_band(unit, 6) == 1, "one lot");
    assert(volume_band(unit * 3, 6) == 1, "three lots");
    assert(volume_band(unit * 4, 6) == 2, "four lots");
    assert(volume_band(unit * 19, 6) == 2, "nineteen lots");
    assert(volume_band(unit * 20, 6) == 3, "twenty lots");
    assert(volume_band(unit * 79, 6) == 3, "just under eighty");
    assert(volume_band(unit * 80, 6) == 4, "eighty lots");
    assert(volume_band(unit * 399, 6) == 4, "just under four hundred");
    assert(volume_band(unit * 400, 6) == 5, "four hundred lots");
}

#[test]
fn volume_bands_are_per_decimals() {
    // The band is denominated in the token's own scale: the same RAW number is a different band in a
    // 6-dec token than in an 18-dec one. This is exactly why `decimals` is a public input — a private
    // one would let a listing claim the top band with dust.
    let six: Field = 250000000; // one lot at 6 decimals
    assert(volume_band(six, 6) == 1, "one lot at 6 decimals");
    assert(volume_band(six, 18) == 0, "the same raw amount is dust at 18 decimals");
}

#[test]
fn volume_bands_match_vectors() {
    // The JS twin's own rows, so the listing a consumer reads and the profile a generator mints
    // cannot drift apart.
    for i in 0..vectors::TIER_COUNT {
        let b = volume_band(vectors::TIER_VOLUMES[i], vectors::TIER_DECIMALS[i]);
        assert(b as Field == vectors::TIER_VOLUME_BANDS[i], "volume band mismatch");
    }
}
