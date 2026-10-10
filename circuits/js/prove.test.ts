// The generator's own drift guard. `prove.ts` writes each circuit's Prover.toml by hand, and
// nargo only complains about a MISSING argument — an extra key is accepted silently. So when a
// circuit's signature changes (a renamed private input, a new public one, a salt that became
// derived), a stale builder either fails loudly on the next run or, worse, keeps writing a key
// nobody reads. Both happened while the disclosure layer was being built.
//
// This reads the two sides as text — `fn main(...)` in every crate against the keys `prove.ts`
// emits for it — and pins them equal, plus the declared `pubs:` count against the `pub`
// arguments (the number the fixture's public-input blob is split by, and the one the consumer
// lib names). Text, because prove.ts runs its whole pipeline at import time: nothing here may
// import it.

import { describe, expect, test } from "bun:test";
import { ATTEST_BASE_PUBS, REVEAL_ADVANCED_PUBS } from "./lib/verify.ts";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const REPO = join(import.meta.dir, "../..");
const CRATES = join(REPO, "circuits/crates");

/** The `fn main` argument names of a crate, in order, with the public ones marked. */
function signature(crate: string): { names: string[]; pubs: number } {
  const src = readFileSync(join(CRATES, crate, "src/main.nr"), "utf8");
  const m = src.match(/\nfn main\(([\s\S]*?)\n\) \{/);
  if (!m) throw new Error(`${crate}: no fn main`);
  const body = m[1].replace(/\/\/[^\n]*/g, "");
  const names = [...body.matchAll(/(\w+)\s*:/g)].map((x) => x[1]);
  // A public array is that many field elements in the proof: `pub [Field; 3]` counts three.
  const pubs = [...body.matchAll(/:\s*pub\s+(\[Field;\s*(\d+)\])?/g)].reduce(
    (n, x) => n + (x[2] ? Number(x[2]) : 1),
    0,
  );
  return { names, pubs };
}

/** The `fn main` argument names a circuit declares `pub`, in the order the proof binds them. */
function publicNames(crate: string): string[] {
  const src = readFileSync(join(CRATES, crate, "src/main.nr"), "utf8");
  const body = src.match(/\nfn main\(([\s\S]*?)\n\) \{/)![1].replace(/\/\/[^\n]*/g, "");
  return [...body.matchAll(/(\w+)\s*:\s*pub\s/g)].map((x) => x[1]);
}

/** The per-circuit blocks of prove.ts's CIRCUIT_LIST: the toml keys and the declared pub count. */
function builders(): Map<string, { keys: string[]; pubs: number; crate?: string }> {
  const src = readFileSync(join(REPO, "circuits/js/prove.ts"), "utf8");
  const out = new Map<string, { keys: string[]; pubs: number; crate?: string }>();
  for (const b of src.matchAll(/name: "(\w+)",([\s\S]*?)\n  \},\n/g)) {
    const keys = [...b[2].matchAll(/`(\w+) = /g)].map((x) => x[1]);
    const pubs = Number(b[2].match(/pubs: (\d+),/)?.[1] ?? -1);
    const crate = b[2].match(/crate: "(\w+)",/)?.[1];
    out.set(b[1], { keys: [...new Set(keys)], pubs, crate });
  }
  return out;
}

describe("prove.ts builds exactly what the circuits declare", () => {
  const list = builders();
  const crates = readdirSync(CRATES).filter((d) => d !== "pluri_commitments");

  test("every crate has a witness builder", () => {
    for (const c of crates) expect(list.has(c)).toBeTrue();
  });

  for (const crate of crates) {
    test(`${crate}: the Prover.toml keys are the circuit's arguments`, () => {
      const { names, pubs } = signature(crate);
      const built = list.get(crate);
      expect(built).toBeDefined();
      // Both directions: a missing key fails the next prove run, an extra one is dead weight
      // that reads as an input the circuit does not have.
      expect([...built!.keys].sort()).toEqual([...names].sort());
      // The declared pub count is what splits the fixture blob and what the consumer lib names.
      expect(built!.pubs).toBe(pubs);
    });
  }

  // The second samples of a circuit (2026-10-01: the open-account shapes) run the same package under
  // their own Prover file: the same keys and pub count are owed to the same signature.
  for (const [name, built] of list) {
    if (!built.crate) continue;
    test(`${name} (a ${built.crate} variant): the Prover keys are that circuit's arguments`, () => {
      const { names, pubs } = signature(built.crate!);
      expect([...built.keys].sort()).toEqual([...names].sort());
      expect(built.pubs).toBe(pubs);
    });
  }

  // The consumer's side of the same wire: verify.ts names the public inputs to split a
  // fixture blob and to re-feed `bb verify`. A name out of ORDER there is the quiet failure —
  // the proof still verifies, against a statement nobody meant.
  test("the consumer lib names attest_base's public inputs in the circuit's order", () => {
    expect([...ATTEST_BASE_PUBS]).toEqual(publicNames("attest_base"));
  });

  test("the consumer lib names reveal_advanced's public inputs in the circuit's order", () => {
    expect([...REVEAL_ADVANCED_PUBS]).toEqual(publicNames("reveal_advanced"));
  });
});
