// Recovering an account's counterparty tree from its secret and the chain (Anexo R, 2026-09-29).
//
// The counterparty tree lives inside the account's leaf, and its leaves are the `S` of the accounts that
// credited it — values the chain never saw in the clear. Before the recovery hints, an account that lost its
// local state could not rebuild that tree, so it could not prove its next claim, and the locks gated by that
// claim were lost with it. The activation now publishes, per side, the counterparty's `S` and the pair secret
// `k` under a pad only the account can rebuild: `hint = value + Poseidon(sk_id, "hint", dealId, which)`.
//
// Everything here takes public data (the `RecoveryHints` events and the deal ids) plus `sk_id`, and nothing
// from a cache.

import { P } from "./fields.ts";
import { CP_DEPTH, cpPath, dealSubject, hintKey } from "./commitments.ts";
import { SparseTree, indexOf } from "./sparse.ts";

export type Hints = { hintS: bigint; hintK: bigint };
export type Opened = { dealId: bigint; sOther: bigint; k: bigint };
/** One `RecoveryHints` event: `(dealId, dealSubject, hintS, hintK)`. */
export type HintRecord = { dealId: bigint; dealSubject: bigint; hintS: bigint; hintK: bigint };

const mod = (x: bigint) => ((x % P) + P) % P;

/** The hints a side publishes for a deal: what the prover puts in `prepare_side`'s `hint_s` / `hint_k`. */
export async function makeHints(skId: bigint, dealId: bigint, sOther: bigint, k: bigint): Promise<Hints> {
  return {
    hintS: mod(sOther + (await hintKey(skId, dealId, 1n))),
    hintK: mod(k + (await hintKey(skId, dealId, 2n))),
  };
}

/** Opens one deal's hints. Only the owner of `skId` gets the right values; anyone else gets noise. */
export async function openHints(skId: bigint, dealId: bigint, h: Hints): Promise<Opened> {
  return {
    dealId,
    sOther: mod(h.hintS - (await hintKey(skId, dealId, 1n))),
    k: mod(h.hintK - (await hintKey(skId, dealId, 2n))),
  };
}

/** From all the chain's hint records, the ones that are this account's — found by recomputing its per-deal
 *  subject, the only thing that links a record to it — opened. */
export async function recoverCounterparties(skId: bigint, records: HintRecord[]): Promise<Opened[]> {
  const mine: Opened[] = [];
  for (const r of records) {
    if ((await dealSubject(skId, r.dealId)) !== r.dealSubject) continue;
    mine.push(await openHints(skId, r.dealId, r));
  }
  return mine;
}

/** The counterparty tree after crediting `credited` in order: each counterparty in the slot its own `S`
 *  addresses, the first time it appears — a second deal with the same account earns nothing (§E.3.14.7). */
export async function counterpartyTree(credited: bigint[]): Promise<SparseTree> {
  const tree = await SparseTree.create(CP_DEPTH);
  const seen = new Set<bigint>();
  for (const s of credited) {
    if (seen.has(s)) continue;
    seen.add(s);
    tree.set(indexOf(await cpPath(s)), s);
  }
  return tree;
}
