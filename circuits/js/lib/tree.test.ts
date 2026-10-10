import { describe, expect, test } from "bun:test";
import { IncrementalPoseidonTree } from "./merkle.ts";
import { PoseidonTreeState, foldPath } from "./tree.ts";

const leaves = (n: number) => Array.from({ length: n }, (_, i) => BigInt(i + 1) * 1000n + 7n);

describe("PoseidonTreeState", () => {
  test("agrees with the incremental twin, which agrees with the contract", async () => {
    for (const n of [0, 1, 2, 3, 5, 8, 9]) {
      const inc = await IncrementalPoseidonTree.create(6);
      for (const leaf of leaves(n)) await inc.insert(leaf);
      const state = await PoseidonTreeState.from(6, leaves(n));
      expect(state.root()).toBe(inc.currentRoot());
    }
  });

  test("every leaf folds to the current root", async () => {
    const state = await PoseidonTreeState.from(6, leaves(9));
    for (let i = 0; i < 9; i++) {
      expect(await foldPath(state.pathFor(i))).toBe(state.root());
    }
  });

  // The reason this module exists. The incremental twin hands back the proof captured at insert
  // time, and later inserts rewrite the siblings of every earlier leaf.
  test("an old leaf still proves, where the incremental twin's stored proof does not", async () => {
    const inc = await IncrementalPoseidonTree.create(6);
    await inc.insert(leaves(1)[0]);
    const stored = inc.proofOf(0);
    for (const leaf of leaves(4).slice(1)) await inc.insert(leaf);

    // The stored proof folds to the root of ITS moment, not to the root now.
    const foldedStored = await foldPath({ ...stored, index: 0, root: 0n });
    expect(foldedStored).not.toBe(inc.currentRoot());

    const state = await PoseidonTreeState.from(6, leaves(4));
    expect(state.root()).toBe(inc.currentRoot());
    expect(await foldPath(state.pathFor(0))).toBe(inc.currentRoot());
  });

  test("finds a leaf by value, which is how a prover locates its own account", async () => {
    const state = await PoseidonTreeState.from(6, leaves(5));
    expect(state.indexOf(leaves(5)[3])).toBe(3);
    expect(state.indexOf(999999n)).toBe(-1);
  });

  test("an empty tree has the empty root and no paths", async () => {
    const state = await PoseidonTreeState.from(4, []);
    expect(state.root()).toBe(state.zeros[4]);
    expect(() => state.pathFor(0)).toThrow();
  });
});
