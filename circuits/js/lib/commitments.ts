// The canonical commitments of the private layer (PROTOCOLO.md §E.3.15.3, amended by the
// canonical-encoding decision of the verifier work): one builder per commitment the
// circuits prove about, implemented identically in Noir (vendored circomlib Poseidon),
// in JS (this twin) and in Solidity (`src/packages/libraries/PrivacyCommitments.sol`).
//
// Multi-field commitments chain PoseidonT3 in a pinned left fold over the field order of
// §E.3.15.3 (h0 = f0, hi = Poseidon2(h(i-1), fi)) — poseidon-solidity has no wide units
// beyond T6, and the tree only ever hashes pairs, so the two-input permutation is the
// single primitive of the whole protocol.
//
// Nullifier tags are pinned field constants (not string hashes): they live inside the
// Poseidon domain of this protocol only, which the canonical library owns end to end.

import { encodeAbiParameters, keccak256 } from "viem";
import { keccak, P } from "./fields.ts";
import { chain, poseidon1, poseidon2 } from "./poseidon.ts";

export const TAG_REP = 1n;
export const TAG_BOND = 2n;
export const TAG_HANDLE = 3n;
export const TAG_LEAF = 4n;
export const TAG_NOTE = 5n;
export const TAG_LOCK = 6n;
export const TAG_PAIR = 7n;
export const TAG_CP = 8n;
export const TAG_FIAT = 9n;
export const TAG_HINT = 10n;
export const TAG_OPERATOR = 11n;
export const TAG_POOL_CP = 12n;
export const TAG_IDENTITY = 13n;

/** `S = Poseidon(sk_id)` — the account; never on-chain in the clear (lives inside leafRep). */
export async function accountCommitment(skId: bigint): Promise<bigint> {
  return poseidon1(skId);
}

/** `identityCommitment = Poseidon("identity", hsk)` — what HumanityRegistry enrolls next to the anchor. Tagged so
 *  it is not `S`: with `hsk == sk_id` an untagged `Poseidon(hsk)` IS the account commitment, which every
 *  counterparty learns, and the public enrollment would link the account to its anchor wallet. */
export async function identityCommitment(hsk: bigint): Promise<bigint> {
  return poseidon2(TAG_IDENTITY, hsk);
}

/** `hn = Poseidon(anchor, registryId)` — the humanity nullifier; anchor = Passport-live address. */
export async function hn(anchor: bigint, registryId: bigint): Promise<bigint> {
  return poseidon2(anchor, registryId);
}

/** `dealSubject = Poseidon(sk_id, dealId)` — the per-deal pseudonym; all the kernel ever sees. */
export async function dealSubject(skId: bigint, dealId: bigint): Promise<bigint> {
  return poseidon2(skId, dealId);
}

/** `nullRep = Poseidon(sk_id, "rep", version)` — one use per account version. */
export async function nullRep(skId: bigint, version: bigint): Promise<bigint> {
  return chain([skId, TAG_REP, version]);
}

/**
 * `leafSalt = Poseidon(sk_id, "leaf", version)` — the account leaf's salt, DERIVED.
 *
 * It used to be whatever the client picked: `hsk` at version zero, a free "rotation" after that.
 * That made an account unrecoverable from its secret. To rebuild your leaf you must reproduce its
 * salt, and without a derivation the only place it lived was the client's local state — which is
 * far easier to lose than a seed phrase, and losing it costs the whole account: reputation, tiers
 * and the bonds gated behind `claimed`.
 *
 * Deriving it costs nothing in privacy. The leaf already hides behind `S = Poseidon(sk_id)`, and
 * anyone who can recompute this salt already holds `sk_id`, which is to say they already own the
 * account. What it buys is that `sk_id` alone is enough: replay your deals from the chain, rebuild
 * your stats, recompute the leaf, find it in the tree.
 *
 * The handle salt stays free on purpose — rotating it IS the feature (§E.3.15.7: another salt is
 * another handle, and the old one dies without linkage).
 */
export async function leafSalt(skId: bigint, version: bigint): Promise<bigint> {
  return chain([skId, TAG_LEAF, version]);
}

/**
 * `noteSalt = Poseidon(sk_id, "note", seed)` — a vault note's salt, DERIVED, for the same reason the
 * account leaf's is ([[leafSalt]]) and with more at stake: a note holds TOKENS, and its salt is what
 * spends it (`nullBond` is taken over the salt). A salt that only lives in a client's local state is
 * money that dies with a laptop.
 *
 * Two seed families, one rule — a note's salt derives from whatever the note came from:
 *   * a DEPOSIT has no parent, so the seed is a small per-account index (the deposit circuit binds it
 *     under 2^32). Recovery walks the index space against the public deposit events.
 *   * every other note is change: the seed is the NULLIFIER of the note or lock it came out of, which
 *     the spending transaction publishes. No counter, no gap — the recovery walk follows the edges
 *     the chain already shows.
 *
 * Recovery works because every amount is public somewhere: a deposit publishes `(token, amount)`, a
 * withdraw its `amount`, a bond split its `lockAmount`, a reabsorb the record's `amount`. A child's
 * amount is its parent's minus something the chain states, and the walk bottoms out at deposits,
 * which are public in full.
 */
export async function noteSalt(skId: bigint, seed: bigint): Promise<bigint> {
  return chain([skId, TAG_NOTE, seed]);
}

/** `lockSalt = Poseidon(sk_id, "lock", dealId)` — the earmark's salt, DERIVED from its deal. One lock
 *  per deal per subject, so the deal id is the only index it needs: `reabsorb` recovers its entire
 *  witness from the public record. */
export async function lockSalt(skId: bigint, dealId: bigint): Promise<bigint> {
  return chain([skId, TAG_LOCK, dealId]);
}

/** `nullBond = Poseidon(sk_id, "bond", noteSalt)` — one use per spent note. */
export async function nullBond(skId: bigint, noteSalt: bigint): Promise<bigint> {
  return chain([skId, TAG_BOND, noteSalt]);
}

/** `handleCommit = Poseidon(sk_id, "handle", handleSalt)` — the rotable market pseudonym. */
export async function handleCommit(skId: bigint, handleSalt: bigint): Promise<bigint> {
  return chain([skId, TAG_HANDLE, handleSalt]);
}

/** `noteBond = Poseidon(sk_id, token, amount, salt)` — token-specific note of the vault (F3). */
export async function noteBond(skId: bigint, token: bigint, amount: bigint, salt: bigint): Promise<bigint> {
  return chain([skId, token, amount, salt]);
}

/** `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` — the earmark a reserve proves openable.
 *  The fold's first step is exactly `dealSubject`: the lock is bound to the deal pseudonym. */
export async function lockCommit(skId: bigint, dealId: bigint, lockAmount: bigint, salt: bigint): Promise<bigint> {
  return chain([skId, dealId, lockAmount, salt]);
}

/**
 * `fiatCommit = Poseidon("fiat", rail, currency, amount, payee, salt)` — the fiat leg of a deal, the one
 * field of `DealTerms` the kernel signs and never reads (§E.3.13).
 *
 *   rail      `railId(name)`: `keccak("pluri:rail:<name>") mod p`
 *   currency  ISO 4217 numeric code (986 BRL, 32 ARS, 840 USD)
 *   amount    minor units of that currency: what the Holder must RECEIVE
 *   payee     the Holder's account on that rail, in the rail's canonical encoding
 *   salt      uniformly random, chosen by the Holder, handed to the Provider off-chain — NOT derived:
 *             it is shared with a counterparty, and a derivation they could follow would open the
 *             Holder's other deals
 *
 * Tag first, like `pairId`: nothing secret in the preimage separates the domain, so the tag does.
 */
export async function fiatCommit(
  rail: bigint,
  currency: bigint,
  amount: bigint,
  payee: bigint,
  salt: bigint,
): Promise<bigint> {
  return chain([TAG_FIAT, rail, currency, amount, payee, salt]);
}

/** A rail's id: `keccak("pluri:rail:<name>") mod p`, the pinned rule for keccak-derived ids. */
export function railId(name: string): bigint {
  return BigInt(keccak(`pluri:rail:${name}`)) % P;
}

/** Depth of an account's own counterparty tree (§E.3.14.7 anti-farming). */
export const CP_DEPTH = 32;

/**
 * `pairId = Poseidon("pair", S_a + S_b, S_a · S_b)` — the name two accounts share, computed
 * commutatively without ordering them (the unordered pair is determined by its sum and product).
 *
 * Each side proves it with its OWN `S` bound to its own leaf and the other's as a private witness,
 * so for two proofs to agree the multisets must match — and since the two `S` differ, each must have
 * used the other's true value. A farmer running both sides cannot mint a fresh pair name per round.
 */
export async function pairId(sA: bigint, sB: bigint): Promise<bigint> {
  return chain([TAG_PAIR, sA + sB, sA * sB]);
}

/** `pairTag = Poseidon(pairId, dealId, k)` — what the two sides of ONE activation publish so the module
 *  can check they named the same counterparty. Blinded by the deal: a bare `pairId` would be equal
 *  across every deal of a pair, which publishes the trading graph. And blinded by `k`, the pair secret
 *  the two sides pick for the deal (Anexo R, 2026-09-29): without it, whoever collected several
 *  counterparties' `S` could test every pair of them against every tag. */
export async function pairTag(sA: bigint, sB: bigint, dealId: bigint, k: bigint): Promise<bigint> {
  return chain([await pairId(sA, sB), dealId, k]);
}

/** `Poseidon(sk_id, "hint", dealId, which)` — the pad an account publishes what it must remember about a
 *  deal under: the counterparty's `S` (which = 1) and the pair secret (which = 2). */
export async function hintKey(skId: bigint, dealId: bigint, which: bigint): Promise<bigint> {
  return chain([skId, TAG_HINT, dealId, which]);
}

/** The slot a counterparty occupies in an account's counterparty tree: the low 32 bits of
 *  `Poseidon("cp", S_other)`, little-endian, one bit per level. Derived, never chosen — otherwise a
 *  claim could point its non-membership proof at whatever empty slot it liked. */
export async function cpPath(sOther: bigint): Promise<number[]> {
  const h = await poseidon2(TAG_CP, sOther);
  let rest = h & 0xffffffffn;
  const bits: number[] = [];
  for (let i = 0; i < CP_DEPTH; i++) {
    bits.push(Number(rest & 1n));
    rest >>= 1n;
  }
  return bits;
}

/** `operatorTag = Poseidon(sk_id, "operator", poolId)` — a pool Controller's operator commitment (Anexo R,
 *  2026-10-05). Registered once in the pool; every vouch proves the human behind the deal's Controller formed
 *  it. Unlinkable across pools. */
export async function operatorTag(skId: bigint, poolId: bigint): Promise<bigint> {
  return chain([skId, TAG_OPERATOR, poolId]);
}

/** `poolCpTag = Poseidon("pool-cp", S_other, poolId)` — the Provider's name in one pool's public counterparty
 *  memory (Anexo R, 2026-10-05): stable across that pool's deals with the Provider, so the pool credits once
 *  per distinct counterparty, and meaningless in any other pool. */
export async function poolCpTag(sOther: bigint, poolId: bigint): Promise<bigint> {
  return chain([TAG_POOL_CP, sOther, poolId]);
}

/** A pool's id in the field: its subject, `keccak256(abi.encode("pluri:pool", pool))`, reduced mod p. */
export function poolId(pool: `0x${string}`): bigint {
  return BigInt(keccak256(encodeAbiParameters([{ type: "string" }, { type: "address" }], ["pluri:pool", pool]))) % P;
}

/** `leafRep = Poseidon(S, count, volume, penalty, inFlight, token, salt, version, cpRoot, epoch,
 *  epochCredits, recCount, recVolume, verified)` — the account leaf. `cpRoot`/`epoch`/`epochCredits`
 *  are the §E.3.14.7 anti-farming state, added 2026-09-23: who has already vouched for this account
 *  (privately, as a tree root), and how much of the current rate window it has spent. The last three
 *  are the open accounts of 2026-10-01: the public RECORD (every completed deal — `count`/`volume` are
 *  the CREDIT that buys tier) and whether a proof of humanity stands behind the account (1) or not (0). */
export async function leafRep(
  s: bigint,
  count: bigint,
  volume: bigint,
  penalty: bigint,
  inFlight: bigint,
  token: bigint,
  salt: bigint,
  version: bigint,
  cpRoot: bigint,
  epoch: bigint,
  epochCredits: bigint,
  recCount: bigint,
  recVolume: bigint,
  verified: bigint,
): Promise<bigint> {
  return chain([
    s,
    count,
    volume,
    penalty,
    inFlight,
    token,
    salt,
    version,
    cpRoot,
    epoch,
    epochCredits,
    recCount,
    recVolume,
    verified,
  ]);
}
