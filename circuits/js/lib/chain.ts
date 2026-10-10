// The chain-consistency reference lib of the disclosure layer (PROTOCOLO.md §E.3.15.7, F4
// as-built). A consumer asking "how has this account behaved over time" receives a
// SEQUENCE of attestations — a disclosure the account owner chose to give, each element
// a true statement about a real state of the account tree. This lib certifies the
// consistency of WHAT WAS DELIVERED:
//
//   * every element verifies (proof + its own semantic checks, via verify.ts);
//   * ONE handleCommit across the whole series — one account's disclosure, not a
//     splice of several (the handle is the only continuity the chain has: the §E.3.15.7
//     model is states, not events, so nothing else binds the series together);
//   * the RAW counters are component-wise monotone NON-DECREASING in the order given:
//     count (attest_base's claim and reveal_advanced's `out_count` are the SAME counter), the
//     listing's volume BAND (a floor over the same figure the reveals state exactly),
//     volume where revealed, and the penalty — which every reveal states raw (§E.3.15.7 keeps
//     it outside the mask). §E.3.15.5's deltas only ever ADD — a decreasing element is a
//     fabricated sequence, and this is the check that catches it;
//   * the FLAG never goes back (2026-10-01): an open account may become verified (`upgrade_account`), a
//     verified one never becomes open — a listing that says `verified = 0` after one that said 1 is a
//     different account, or a fabrication;
//   * the PENALTY BAND of a listing is checked against the exact penalties already revealed
//     earlier in the series: a reveal is exact and a band claim must COVER the account's real
//     one, so a listing claiming a band under evidence the same series already handed over is
//     inconsistent with itself. (The other direction is allowed and not flagged — an
//     overstated band is a true if unflattering statement, and it only ever costs its author.)
//
// What this lib deliberately does NOT do:
//   * the TIER is not monotone — a Stalemate (+5) can drop a T2 account to T1 mid-chain,
//     and an honest chain shows exactly that; checking tiers for decrease would reject
//     the honest case the design wants visible;
//   * the GAPS are not priced here — the user's selection freedom (which elements to
//     hand over) is bounded only by the consumer's own receipts: verifyAttestationChain
//     certifies what arrived, the cadence policy (and the price of a missing month) is
//     the consumer's, per §E.3.15.7's "el listado muestra attestations frescas".
//
// Pure logic over verify.ts — no bb, no chain reads the consumer did not inject.

import { penaltyBand } from "./tiers.ts";
import {
  AttestBasePubs,
  AttestationEnvelope,
  RevealAdvancedPubs,
  VerifyOpts,
  VerifyResult,
  verifyAttestationBase,
  verifyAttestationReveal,
} from "./verify.ts";

export type ChainElement =
  | ({ kind: "base" } & AttestationEnvelope<AttestBasePubs>)
  | ({ kind: "reveal" } & AttestationEnvelope<RevealAdvancedPubs>);

/** Verify a delivered attestation series: per-element verification + the one-handle and
 *  raw-monotonicity consistency checks. `opts` is verify.ts's (clock, decimals, root
 *  liveness, proof verifier) — inject the chain reads; the lib adds no reads of its own. */
export async function verifyAttestationChain(
  chain: ChainElement[],
  opts: VerifyOpts,
): Promise<VerifyResult> {
  const errors: string[] = [];
  const checks: string[] = [];

  if (chain.length === 0) {
    errors.push("empty chain — nothing was disclosed");
    return { ok: false, errors, checks: [] };
  }

  // One handle across the series (checked first: a spliced chain fails before anything
  // else does, with the clearest message).
  const handle = chain[0].pubs.handle_commit;
  let oneHandle = true;
  chain.forEach((el, i) => {
    if (el.pubs.handle_commit !== handle) {
      errors.push(`element ${i}: handle_commit differs from element 0 — two accounts spliced?`);
      oneHandle = false;
    }
  });
  if (oneHandle) checks.push(`one handle across ${chain.length} elements`);

  // Per-element verification (the consumer's injected checks ride along).
  for (const [i, el] of chain.entries()) {
    const r = el.kind === "base" ? await verifyAttestationBase(el, opts) : await verifyAttestationReveal(el, opts);
    for (const e of r.errors) errors.push(`element ${i}: ${e}`);
    checks.push(`element ${i}: ${r.checks.join("; ")}`);
  }

  // Raw monotonicity, in the order delivered (the consumer orders by its receipts), plus
  // the band/penalty cross-check. `floorBand` is the band the exact penalties revealed so far
  // already prove — the evidence a later listing cannot claim under.
  let lastCount: bigint | undefined;
  let lastVolume: bigint | undefined;
  let lastPenalty: bigint | undefined;
  let lastVolumeBand: number | undefined;
  let wasVerified = false;
  let floorBand = 0;
  chain.forEach((el, i) => {
    if (el.kind === "base") {
      const count = BigInt(el.pubs.count);
      if (lastCount !== undefined && count < lastCount) {
        errors.push(`element ${i}: count ${count} decreased from ${lastCount} — count never decreases (§E.3.15.5)`);
      }
      lastCount = count;
      // The volume band is a floor over the same figure, so it tracks with the same policy: the
      // underlying volume only ever grows, and a series whose floors walk backwards is fabricated.
      const vband = Number(BigInt(el.pubs.volume_band));
      if (lastVolumeBand !== undefined && vband < lastVolumeBand) {
        errors.push(`element ${i}: volume band ${vband} decreased from ${lastVolumeBand} — volume never decreases (§E.3.15.5)`);
      }
      lastVolumeBand = vband;
      const verified = BigInt(el.pubs.verified) === 1n;
      if (wasVerified && !verified) {
        errors.push(`element ${i}: open after an earlier verified listing — an account is never un-verified`);
      }
      wasVerified = wasVerified || verified;
      const band = Number(BigInt(el.pubs.penalty_band));
      if (band < floorBand) {
        errors.push(
          `element ${i}: penalty band ${band} under band ${floorBand}, already revealed exactly earlier in this series`,
        );
      }
    } else {
      const mask = Number(BigInt(el.pubs.fields_mask));
      if (mask & 1) {
        const count = BigInt(el.pubs.out_count);
        if (lastCount !== undefined && count < lastCount) {
          errors.push(`element ${i}: count ${count} decreased from ${lastCount} — count never decreases (§E.3.15.5)`);
        }
        lastCount = count;
      }
      if (mask & 2) {
        const volume = BigInt(el.pubs.out_volume);
        if (lastVolume !== undefined && volume < lastVolume) {
          errors.push(`element ${i}: volume ${volume} decreased from ${lastVolume} — volume never decreases (§E.3.15.5)`);
        }
        lastVolume = volume;
      }
      // The penalty rides outside the mask: every reveal states it exactly, so it tracks
      // unconditionally — and it is the evidence the later listings are held to.
      const penalty = BigInt(el.pubs.out_penalty);
      if (lastPenalty !== undefined && penalty < lastPenalty) {
        errors.push(`element ${i}: penalty ${penalty} decreased from ${lastPenalty} — penalty never decreases (§E.3.15.5)`);
      }
      lastPenalty = penalty;
      floorBand = Math.max(floorBand, penaltyBand(penalty));
    }
  });

  return { ok: errors.length === 0, errors, checks };
}
