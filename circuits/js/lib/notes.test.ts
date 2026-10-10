// The vault's recovery property, against the committed flow.
//
// The fixtures are one deal's whole vault lifecycle: a deposit of 1_500_000_000, a split that
// earmarks §E.3.14.5's lock for the deal, the released lock reabsorbed after the terminal claim, and
// a partial withdraw out of the change. This suite replays it from `sk_id` and the PUBLIC facts
// only — the deposit event's `(token, amount, note)`, the split's `lockAmount`, the withdraw's
// `amount`, the record's `amount` — and asserts every commitment lands on the committed value.
//
// If it passes, an owner who kept nothing can rebuild the vault. That is the whole claim behind
// deriving the note salts, and it is the only place it can be checked as a fact rather than argued.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { depositNote, findDeposit, reabsorb, split, withdraw } from "./notes.ts";

const v = JSON.parse(readFileSync("test/fixtures/vectors.json", "utf8"));
const SK_ID = BigInt(v.deposit.sk_id);
const TOKEN = BigInt(v.deposit.token);

describe("the vault comes back from the secret and the chain", () => {
  test("the deposit's note, from its index", async () => {
    const n = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    expect(n.commitment).toBe(BigInt(v.deposit.note));
    expect(n.salt).toBe(BigInt(v.deposit.salt));
  });

  test("and from the event alone, by walking the index window", async () => {
    // What an owner actually has after losing everything: the deposit events. `(token, amount,
    // note)` are all public, so the index is the only unknown — and it is a small one.
    const found = await findDeposit(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.note));
    expect(found).not.toBeNull();
    expect(found!.salt).toBe(BigInt(v.deposit.salt));
    expect(found!.nullifier).toBe(BigInt(v.bond.null_bond)); // what the split later burned
  });

  test("a stranger's secret finds nothing in the same window", async () => {
    const found = await findDeposit(SK_ID + 1n, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.note));
    expect(found).toBeNull();
  });

  test("the split: the earmark from the deal, the change from the burn", async () => {
    const parent = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    const { lock, change } = await split(SK_ID, parent, BigInt(v.bond.deal_id), BigInt(v.bond.lock_amount));
    expect(lock.commitment).toBe(BigInt(v.bond.lock_commit));
    expect(lock.salt).toBe(BigInt(v.bond.lock_salt));
    expect(change!.commitment).toBe(BigInt(v.bond.change_note));
    expect(change!.salt).toBe(BigInt(v.bond.change_salt));
    // Conservation, restated by the walk: the two halves are the parent.
    expect(lock.amount + change!.amount).toBe(parent.amount);
  });

  test("the reabsorb: the released lock merges back whole", async () => {
    const parent = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    const { lock } = await split(SK_ID, parent, BigInt(v.bond.deal_id), BigInt(v.bond.lock_amount));
    expect(lock.nullifier).toBe(BigInt(v.reabsorb.null_bond));
    const merged = await reabsorb(SK_ID, lock);
    expect(merged.commitment).toBe(BigInt(v.reabsorb.new_note));
    expect(merged.amount).toBe(BigInt(v.reabsorb.amount));
  });

  test("the reabsorb after a court's share: the commit is the lock's, the note what is left", async () => {
    const parent = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    const { lock } = await split(SK_ID, parent, BigInt(v.bond.deal_id), BigInt(v.bond.lock_amount));
    const merged = await reabsorb(SK_ID, lock, BigInt(v.reabsorb.cut_kept));
    expect(merged.commitment).toBe(BigInt(v.reabsorb.cut_new_note));
    expect(merged.amount).toBe(BigInt(v.reabsorb.cut_kept));
    // The same nullifier seeds both: what a court took changes the amount, never which note it is.
    expect(merged.salt).toBe((await reabsorb(SK_ID, lock)).salt);
    expect(reabsorb(SK_ID, lock, lock.amount + 1n)).rejects.toThrow("kept over the lock");
    expect(reabsorb(SK_ID, lock, 0n)).rejects.toThrow("kept over the lock");
  });

  test("the withdraw: the change of the change", async () => {
    const parent = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    const { change } = await split(SK_ID, parent, BigInt(v.bond.deal_id), BigInt(v.bond.lock_amount));
    expect(change!.nullifier).toBe(BigInt(v.withdraw.null_bond));
    const rest = await withdraw(SK_ID, change!, BigInt(v.withdraw.amount));
    expect(rest!.commitment).toBe(BigInt(v.withdraw.change_note));
    expect(rest!.amount).toBe(BigInt(v.bond.note_amount) - BigInt(v.bond.lock_amount) - BigInt(v.withdraw.amount));
  });

  test("a note consumed whole leaves no change to find", async () => {
    // §E.3.15.6's masked branch: the circuit publishes `changeNote == 0`, and the walk agrees —
    // there is no child note to look for in the tree.
    const parent = await depositNote(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.index));
    expect(await withdraw(SK_ID, parent, parent.amount)).toBeNull();
  });

  test("the whole lifecycle, in one walk, from four public numbers", async () => {
    // The claim end to end: nothing enters this test but the secret and what the chain states.
    const deposited = await findDeposit(SK_ID, TOKEN, BigInt(v.deposit.amount), BigInt(v.deposit.note));
    const { lock, change } = await split(SK_ID, deposited!, BigInt(v.bond.deal_id), BigInt(v.bond.lock_amount));
    const merged = await reabsorb(SK_ID, lock);
    const rest = await withdraw(SK_ID, change!, BigInt(v.withdraw.amount));
    // The vault's live balance after it all: the merged lock plus what the withdraw left.
    expect(merged.commitment).toBe(BigInt(v.reabsorb.new_note));
    expect(rest!.commitment).toBe(BigInt(v.withdraw.change_note));
    expect(merged.amount + rest!.amount).toBe(BigInt(v.deposit.amount) - BigInt(v.withdraw.amount));
  });
});
