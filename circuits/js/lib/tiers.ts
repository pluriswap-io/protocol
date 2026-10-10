// The admission tiers of PROTOCOLO.md §E.3.14.7 — the JS twin. The same table the circuit
// computes in-circuit (`pluri_commitments::tiers`) and the on-chain reputation reads
// (`Reputation.score` / `Reputation._capTokens`); test/fixtures/vectors.json pins the
// three against each other.
//
//   score = satSub(count + volume / UNIT, penalty),   UNIT = 250 * 10^decimals
//
// Integer division (truncated) on the volume, saturating subtraction on the penalty.
// The caps are per-token integers: base and with-bond columns, T5 unbounded.

/** The tier's score, computed exactly as §E.3.14.7's Solidity view: truncating division and
 *  saturating subtraction, all integer. */
export function score(count: bigint, volume: bigint, penalty: bigint, decimals: bigint): bigint {
  const unit = 250n * 10n ** decimals;
  const raw = count + volume / unit;
  return raw > penalty ? raw - penalty : 0n;
}

/** The cap in whole tokens of the tier a score buys, or null when unbounded.
 *  Mirrors `Reputation._capTokens`'s table — thresholds 0/10/25/50/100, base column
 *  250/500/1000/2000/5000, bond column 400/700/1500/5000/unbounded.
 *
 *  Only T5's BOND column is unbounded (2026-09-23): the protocol's one unlimited exposure now
 *  requires a live lock, so it is always 10% backed. Without bond the ladder tops out at 5.000. */
export function capUnits(sc: bigint, withBond: boolean): bigint | null {
  if (sc >= 100n) return withBond ? null : 5000n;
  if (sc >= 50n) return withBond ? 5000n : 2000n;
  if (sc >= 25n) return withBond ? 1500n : 1000n;
  if (sc >= 10n) return withBond ? 700n : 500n;
  return withBond ? 400n : 250n;
}

/** The cap in raw token units (`capUnits * 10^decimals`), or null when unbounded. */
export function capRaw(sc: bigint, withBond: boolean, decimals: bigint): bigint | null {
  const units = capUnits(sc, withBond);
  return units === null ? null : units * 10n ** decimals;
}

/** The tier ordinal a score buys (1..5) — the disclosure layer's (F4) reading of the same
 *  ladder: `attest_base`'s claimed tier is a LOWER bound of this. `capUnits` returns 0
 *  for T5; here the ordinal is explicit — the attestation's public semantics is the
 *  tier, not the cap. */
export function tierOf(sc: bigint): bigint {
  if (sc >= 100n) return 5n;
  if (sc >= 50n) return 4n;
  if (sc >= 25n) return 3n;
  if (sc >= 10n) return 2n;
  return 1n;
}

/**
 * The volume BAND of §E.3.15.7 — the other aggregate a public listing carries, where the exact figure
 * belongs to the advanced reveal.
 *
 * The cuts are LOTS (`UNIT = 250 * 10^decimals`), the same unit the score buys tier with, so the
 * band reads correctly in any token at any scale. In whole tokens the floors are 250, 1.000, 5.000,
 * 20.000, 100.000 — see [[volumeBandFloor]], which is what a listing renders, since `token` and
 * `decimals` ride public alongside.
 *
 * A LOWER bound, like tier and count: understating what you moved is a weaker true statement,
 * overstating it has no witness. The band rather than the figure because a listing is read by
 * everyone and an exact volume is a fingerprint.
 */
export function volumeBand(volume: bigint, decimals: bigint): number {
  const lots = volume / (250n * 10n ** decimals);
  if (lots >= 400n) return 5;
  if (lots >= 80n) return 4;
  if (lots >= 20n) return 3;
  if (lots >= 4n) return 2;
  if (lots >= 1n) return 1;
  return 0;
}

/** The band's floor in WHOLE tokens — what a listing shows ("≥ 5.000 USDC"). Band 0 has no floor
 *  to state: it means less than one lot, which is the honest way to render a fresh account. */
export function volumeBandFloor(band: number): bigint | null {
  return [null, 250n, 1000n, 5000n, 20000n, 100000n][band] ?? null;
}

/**
 * The penalty BAND of §E.3.15.7 — the aggregate a public listing carries, where the raw counter
 * belongs to the advanced reveal. A listing is read by everyone, and a raw counter is a
 * fingerprint; a band informs without identifying.
 *
 * The cuts are events, not round numbers: a tribunal's stalemate, an abandoned dispute or a Provider's
 * no-show is +5, a deadlock is +10, an arbitration loss is +15. So 0 is clean, 1 is one bad clock, 2 is several, one
 * deadlock or one proven loss, 3 is more.
 *
 * It is what makes the tier readable. The tier nets penalty into the score, so a punished T2 falls
 * to T1 and looks exactly like an honest newcomer — the one distinction a counterparty needs most.
 */
export function penaltyBand(penalty: bigint): number {
  if (penalty >= 16n) return 3;
  if (penalty >= 6n) return 2;
  if (penalty >= 1n) return 1;
  return 0;
}
