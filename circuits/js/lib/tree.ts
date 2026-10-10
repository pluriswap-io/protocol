// A Poseidon Merkle tree held as its full leaf set, which is what a prover needs and what the
// incremental twin cannot give it.
//
// `IncrementalPoseidonTree` (merkle.ts) mirrors the contract: it inserts, it tracks the frontier,
// and it hands back the membership proof captured AT INSERT TIME. That proof is only valid against
// the root of that moment. Every later insert rewrites the siblings of every earlier leaf, so a user
// who inserted a leaf on Monday and wants to prove membership on Friday cannot reuse it — and the
// contract's root ring is finite, so the Monday root will eventually fall out of `isKnownRoot`.
//
// This class keeps the leaves and recomputes, so `pathFor` always answers against the CURRENT root.
// It never materialises the tree: at depth 32 that would be four billion nodes. Positions past the
// last leaf are the zero subtree of their level, so folding only the filled prefix — n, then n/2,
// then n/4 — is exact and costs O(n).

import { poseidon2 } from "./poseidon.ts";

export type Path = {
  leaf: bigint;
  index: number;
  /** Sibling at each level, bottom-up. */
  siblings: bigint[];
  /** 0 = the node sits on the left at that level, 1 = on the right. */
  indices: number[];
  /** The root this path folds to: the tree's current root. */
  root: bigint;
};

export class PoseidonTreeState {
  readonly depth: number;
  readonly zeros: bigint[];
  /** Level 0 is the leaves; level `depth` is the single root node. */
  private readonly levels: bigint[][];

  private constructor(depth: number, zeros: bigint[], levels: bigint[][]) {
    this.depth = depth;
    this.zeros = zeros;
    this.levels = levels;
  }

  static async zerosFor(depth: number): Promise<bigint[]> {
    const zeros: bigint[] = [0n];
    for (let level = 1; level <= depth; level++) {
      zeros.push(await poseidon2(zeros[level - 1], zeros[level - 1]));
    }
    return zeros;
  }

  /** Folds the leaf set once; every `pathFor` afterwards is a lookup, not a rebuild. */
  static async from(depth: number, leaves: bigint[]): Promise<PoseidonTreeState> {
    if (depth < 1 || depth > 32) throw new Error("depth out of range");
    if (leaves.length > 2 ** depth) throw new Error("more leaves than the tree holds");
    const zeros = await PoseidonTreeState.zerosFor(depth);
    const levels: bigint[][] = [leaves.slice()];
    for (let level = 0; level < depth; level++) {
      const current = levels[level];
      const next: bigint[] = [];
      for (let i = 0; i < current.length; i += 2) {
        const left = current[i] ?? zeros[level];
        const right = current[i + 1] ?? zeros[level];
        next.push(await poseidon2(left, right));
      }
      levels.push(next);
    }
    return new PoseidonTreeState(depth, zeros, levels);
  }

  get size(): number {
    return this.levels[0].length;
  }

  /** The current root — the empty-tree root when there are no leaves. */
  root(): bigint {
    return this.levels[this.depth][0] ?? this.zeros[this.depth];
  }

  leafAt(index: number): bigint | undefined {
    return this.levels[0][index];
  }

  /** First index holding `leaf`, or -1. A prover uses this to find its own account. */
  indexOf(leaf: bigint): number {
    return this.levels[0].findIndex((l) => l === leaf);
  }

  /** Membership of the leaf at `index`, against the CURRENT root. */
  pathFor(index: number): Path {
    const leaf = this.levels[0][index];
    if (leaf === undefined) throw new Error(`no leaf at index ${index}`);
    const siblings: bigint[] = [];
    const indices: number[] = [];
    let cursor = index;
    for (let level = 0; level < this.depth; level++) {
      const sibling = this.levels[level][cursor ^ 1] ?? this.zeros[level];
      siblings.push(sibling);
      indices.push(cursor & 1);
      cursor >>= 1;
    }
    return { leaf, index, siblings, indices, root: this.root() };
  }
}

/** Folds a path back to a root. The check a circuit performs, available to the caller first. */
export async function foldPath(path: Path): Promise<bigint> {
  let node = path.leaf;
  for (let level = 0; level < path.siblings.length; level++) {
    node = path.indices[level] === 1
      ? await poseidon2(path.siblings[level], node)
      : await poseidon2(node, path.siblings[level]);
  }
  return node;
}
