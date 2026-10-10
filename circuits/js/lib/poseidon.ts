// Circomlib-compatible Poseidon over BN254 (PROTOCOLO.md §E.3.15.3), JS twin of the
// vendored Noir implementation and of poseidon-solidity. Parity is pinned by the
// circomlib vector `poseidonperm_x5_254_3([1,2])` (see test/PoseidonTree.t.sol) and by
// the triple-parity vectors (test/fixtures/vectors.json).
//
// The reference implementation is iden3/circomlibjs `buildPoseidonReference` — the same
// parameterization as circomlib's PoseidonT2/PoseidonT3 templates: 8 full rounds,
// partial rounds by width (t=2: 56, t=3: 57), x^5 S-box, capacity 0 first, output
// state[0]. We do NOT use Noir's `std::hash::poseidon`: the canonical parameters of the
// protocol are circomlib's, pinned on-chain by poseidon-solidity.

import { buildPoseidonReference } from "circomlibjs";
import { fromMontgomeryLE } from "./fields.ts";

type Reference = (inputs: bigint[]) => unknown;

let reference: Reference | null = null;

async function ensure(): Promise<Reference> {
  if (!reference) {
    reference = (await buildPoseidonReference()) as unknown as Reference;
  }
  return reference;
}

async function perm(inputs: bigint[]): Promise<bigint> {
  const poseidon = await ensure();
  const montgomery = new Uint8Array(poseidon(inputs) as unknown as Iterable<number>);
  return fromMontgomeryLE(montgomery);
}

/** PoseidonT2: one input, one field element out (`S = Poseidon(sk_id)`). */
export async function poseidon1(x: bigint): Promise<bigint> {
  return perm([x]);
}

/** PoseidonT3: two inputs, one field element out (tree nodes, hn, dealSubject, chaining). */
export async function poseidon2(a: bigint, b: bigint): Promise<bigint> {
  return perm([a, b]);
}

/** Left-fold chaining of a multi-field commitment: h0 = f0, hi = poseidon2(h(i-1), fi). */
export async function chain(fields: bigint[]): Promise<bigint> {
  let h = fields[0];
  for (let i = 1; i < fields.length; i++) {
    h = await poseidon2(h, fields[i]);
  }
  return h;
}
