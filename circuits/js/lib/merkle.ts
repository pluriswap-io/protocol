// JS twin of `src/packages/PoseidonTree.sol`: the incremental binary Merkle tree the
// private layer's proofs reference. Same algorithm (zk-kit insert), same hashing
// (PoseidonT3 on pairs), same zero leaves — so roots produced here are the roots the
// contract produces, which is what the fixtures of the real-proof tests rely on.

import { poseidon2 } from "./poseidon.ts";

export type Membership = {
  leaf: bigint;
  index: bigint;
  siblings: bigint[];
  indices: number[]; // 0 = node sits on the left, 1 = on the right
  root: bigint;
};

export class IncrementalPoseidonTree {
  readonly depth: number;
  readonly zeros: bigint[];
  private filled: bigint[];
  private root: bigint;
  private roots: bigint[];
  private proofs: Membership[];
  nextIndex: bigint;

  private constructor(
    depth: number,
    zeros: bigint[],
    filled: bigint[],
    root: bigint,
    roots: bigint[],
    proofs: Membership[],
  ) {
    this.depth = depth;
    this.zeros = zeros;
    this.filled = filled;
    this.root = root;
    this.roots = roots;
    this.proofs = proofs;
    this.nextIndex = 0n;
  }

  static async create(depth: number): Promise<IncrementalPoseidonTree> {
    if (depth < 1 || depth > 32) throw new Error("depth out of range");
    const zeros: bigint[] = [0n];
    for (let level = 1; level <= depth; level++) {
      zeros.push(await poseidon2(zeros[level - 1], zeros[level - 1]));
    }
    const emptyRoot = zeros[depth];
    return new IncrementalPoseidonTree(depth, zeros, zeros.slice(0, depth), emptyRoot, [emptyRoot], []);
  }

  currentRoot(): bigint {
    return this.root;
  }

  /** Roots after each insert, plus the seeded empty root at position 0. */
  rootHistory(): bigint[] {
    return this.roots;
  }

  async insert(leaf: bigint): Promise<bigint> {
    if (leaf === 0n) throw new Error("zero leaf");
    if (this.nextIndex >= 1n << BigInt(this.depth)) throw new Error("tree full");
    const siblings: bigint[] = [];
    const indices: number[] = [];
    let node = leaf;
    let cursor = this.nextIndex;
    for (let level = 0; level < this.depth; level++) {
      if (cursor & 1n) {
        siblings.push(this.filled[level]);
        indices.push(1);
        node = await poseidon2(this.filled[level], node);
      } else {
        siblings.push(this.zeros[level]);
        indices.push(0);
        this.filled[level] = node;
        node = await poseidon2(node, this.zeros[level]);
      }
      cursor >>= 1n;
    }
    this.root = node;
    this.roots.push(this.root);
    const index = this.nextIndex;
    this.proofs.push({ leaf, index, siblings, indices, root: this.root });
    this.nextIndex += 1n;
    return this.root;
  }

  /** Membership proof of a past insert (the witness a circuit consumes). */
  proofOf(index: number): Membership {
    const p = this.proofs[index];
    if (!p) throw new Error("no insert at index");
    return p;
  }
}
