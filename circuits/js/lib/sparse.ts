// The sparse tree an account keeps of its own counterparties (§E.3.14.7 anti-farming, 2026-09-23).
//
// Different animal from `merkle.ts`'s incremental tree, and for a reason: that one is append-only and
// a contract owns it, so a leaf's position is whatever the next index happens to be. This one is
// addressed by CONTENT — a counterparty's slot is `cpPath(S_other)`, the low 32 bits of a hash — so
// that a claim cannot point its non-membership proof at whatever empty slot it likes. Nobody owns it:
// it lives as a root inside the account's own leaf, and only the claim circuit ever updates it.
//
// Sparse means almost every slot is the zero subtree, so the root and any path are computed from the
// handful of entries that exist plus the precomputed zeros — never by materialising 2^32 leaves.
//
// A collision (two counterparties whose paths agree in all 32 bits) reads as "already known" and
// denies credit. That is the safe direction, and at a few hundred entries it happens with probability
// around 10^-4. The unsafe direction — a known counterparty reading as fresh — would need a Poseidon
// preimage, not a birthday.

import { poseidon2 } from "./poseidon.ts";

export type SparsePath = { siblings: bigint[]; indices: number[] };

export class SparseTree {
  readonly depth: number;
  private zeros: bigint[] = [];
  private entries = new Map<bigint, bigint>();

  private constructor(depth: number) {
    this.depth = depth;
  }

  static async create(depth: number): Promise<SparseTree> {
    const t = new SparseTree(depth);
    t.zeros = [0n];
    for (let level = 1; level <= depth; level++) {
      t.zeros.push(await poseidon2(t.zeros[level - 1], t.zeros[level - 1]));
    }
    return t;
  }

  /** The root of a tree with nothing in it — what a fresh account's leaf carries. */
  emptyRoot(): bigint {
    return this.zeros[this.depth];
  }

  get size(): number {
    return this.entries.size;
  }

  has(index: bigint): boolean {
    return this.entries.has(index);
  }

  /** The value in a slot: the counterparty's `S` when taken, zero when free. */
  valueAt(index: bigint): bigint {
    return this.entries.get(index) ?? 0n;
  }

  set(index: bigint, value: bigint): void {
    this.entries.set(index, value);
  }

  /** Root of the subtree at `level` covering every index whose high bits are `hi`. */
  private async subtree(level: number, hi: bigint): Promise<bigint> {
    if (level === 0) return this.entries.get(hi) ?? 0n;
    let occupied = false;
    for (const k of this.entries.keys()) {
      if (k >> BigInt(level) === hi) {
        occupied = true;
        break;
      }
    }
    if (!occupied) return this.zeros[level];
    const left = await this.subtree(level - 1, hi * 2n);
    const right = await this.subtree(level - 1, hi * 2n + 1n);
    return poseidon2(left, right);
  }

  async root(): Promise<bigint> {
    return this.subtree(this.depth, 0n);
  }

  /** The witness a circuit consumes: one sibling and one direction bit per level, little-endian —
   *  the same shape `merkle.nr`'s `compute_root` folds and `cpPath` produces. */
  async pathFor(index: bigint): Promise<SparsePath> {
    const siblings: bigint[] = [];
    const indices: number[] = [];
    for (let level = 0; level < this.depth; level++) {
      const node = index >> BigInt(level);
      siblings.push(await this.subtree(level, node ^ 1n));
      indices.push(Number(node & 1n));
    }
    return { siblings, indices };
  }
}

/** The index a path of direction bits addresses — the inverse of `cpPath`. */
export function indexOf(bits: number[]): bigint {
  let idx = 0n;
  for (let i = bits.length - 1; i >= 0; i--) idx = idx * 2n + BigInt(bits[i]);
  return idx;
}
