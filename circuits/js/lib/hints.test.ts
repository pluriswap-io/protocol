// The counterparty tree comes back from the secret and the chain.
//
// The committed sample publishes its side's hints in `prepare_side`; the claim credits that counterparty.
// Recovering from `sk_id` and the hint record alone must reach the claim's committed counterparty root.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dealSubject } from "./commitments.ts";
import { counterpartyTree, makeHints, openHints, recoverCounterparties } from "./hints.ts";

const v = JSON.parse(readFileSync("test/fixtures/vectors.json", "utf8"));
const SK_ID = BigInt(v.prepare.sk_id);
const DEAL = BigInt(v.prepare.deal_id);

describe("recovery hints", () => {
  test("the committed hints are the ones the prover would make", async () => {
    const h = await makeHints(SK_ID, DEAL, BigInt(v.prepare.cp_s), BigInt(v.prepare.pair_secret));
    expect(h.hintS).toBe(BigInt(v.prepare.hint_s));
    expect(h.hintK).toBe(BigInt(v.prepare.hint_k));
  });

  test("the owner opens them to the counterparty and the pair secret", async () => {
    const o = await openHints(SK_ID, DEAL, { hintS: BigInt(v.prepare.hint_s), hintK: BigInt(v.prepare.hint_k) });
    expect(o.sOther).toBe(BigInt(v.prepare.cp_s));
    expect(o.k).toBe(BigInt(v.prepare.pair_secret));
  });

  test("anyone else opens noise", async () => {
    const o = await openHints(SK_ID + 1n, DEAL, { hintS: BigInt(v.prepare.hint_s), hintK: BigInt(v.prepare.hint_k) });
    expect(o.sOther).not.toBe(BigInt(v.prepare.cp_s));
    expect(o.k).not.toBe(BigInt(v.prepare.pair_secret));
  });

  test("from every record on chain, the account finds its own and rebuilds the claim's counterparty root", async () => {
    const records = [
      // somebody else's side of some other deal
      { dealId: DEAL + 7n, dealSubject: 123n, hintS: 1n, hintK: 2n },
      // this account's side of the sample deal
      {
        dealId: DEAL,
        dealSubject: await dealSubject(SK_ID, DEAL),
        hintS: BigInt(v.prepare.hint_s),
        hintK: BigInt(v.prepare.hint_k),
      },
    ];
    const mine = await recoverCounterparties(SK_ID, records);
    expect(mine.length).toBe(1);
    const tree = await counterpartyTree(mine.map((o) => o.sOther));
    expect(await tree.root()).toBe(BigInt(v.claim.cp_root_after));
  });

  test("a second deal with the same account adds nothing to the tree", async () => {
    const s = BigInt(v.prepare.cp_s);
    const once = await counterpartyTree([s]);
    const twice = await counterpartyTree([s, s]);
    expect(await twice.root()).toBe(await once.root());
  });
});
