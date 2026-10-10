// Recovering a private account from its secret and the chain.
//
// This is the property the derived leaf salt exists for (§E.3.15.3). Before it, rebuilding your leaf
// meant reproducing a salt that only lived in your client's local state, so an account was
// recoverable from a database rather than from a secret. Now `sk_id` is enough, and this is the
// code that shows it: compute the candidate leaf, find it in the tree the contract owns.
//
// What it deliberately does NOT do is trust a local cache. Every value here comes from the chain or
// from the secret. If a client's state is lost, wrong, or was never written, recovery still works.

import type { Address, PublicClient } from "viem";
import { CP_DEPTH, accountCommitment, dealSubject, leafRep, leafSalt, nullRep } from "./commitments.ts";
import { SparseTree } from "./sparse.ts";
import type { TreeSnapshot } from "./indexer.ts";
import type { Path } from "./tree.ts";

/** The stats a leaf carries, in `leafRep` field order. */
export type Stats = {
  count: bigint;
  volume: bigint;
  penalty: bigint;
  inFlight: bigint;
  /** The token the stats are denominated in; zero on the genesis leaf. */
  token: bigint;
  /** The §E.3.14.7 anti-farming state: the root of this account's counterparty tree, and the rate
   *  window it is in. A fresh account carries the empty tree and a cold window. */
  cpRoot: bigint;
  epoch: bigint;
  epochCredits: bigint;
  /** The public record (2026-10-01): every completed deal and its volume, credited or not. `count` and
   *  `volume` above are the CREDIT — what buys tier, once per counterparty, between verified accounts. */
  recCount: bigint;
  recVolume: bigint;
  /** 1 when a proof of humanity stands behind the account, 0 for an open account. */
  verified: bigint;
};

/** The genesis state: every counter zero, no token, an EMPTY counterparty tree (it has met nobody)
 *  and a cold rate window. `cpRoot` is computed lazily because the empty root is a fold of zeros.
 *  `verified` is the registration's: a verified account (the default) or an open one. */
export async function genesis(verified = true): Promise<Stats> {
  const tree = await SparseTree.create(CP_DEPTH);
  return {
    count: 0n,
    volume: 0n,
    penalty: 0n,
    inFlight: 0n,
    token: 0n,
    cpRoot: tree.emptyRoot(),
    epoch: 0n,
    epochCredits: 0n,
    recCount: 0n,
    recVolume: 0n,
    verified: verified ? 1n : 0n,
  };
}

export type AccountState = {
  skId: bigint;
  /** `S = Poseidon(sk_id)` — what the leaf actually commits to. */
  s: bigint;
  version: bigint;
  stats: Stats;
  /** Where the leaf sits in the accounts tree. */
  index: number;
  /** Membership against the tree's CURRENT root, ready to hand a circuit. */
  path: Path;
  /** The nullifier the next transition will burn. Already spent means this version moved on. */
  nextNullifier: bigint;
};

/** The leaf a given secret and state commit to. No stored salt: the salt is derived. */
export async function leafFor(skId: bigint, stats: Stats, version: bigint): Promise<bigint> {
  const s = await accountCommitment(skId);
  return leafRep(
    s,
    stats.count,
    stats.volume,
    stats.penalty,
    stats.inFlight,
    stats.token,
    await leafSalt(skId, version),
    version,
    stats.cpRoot,
    stats.epoch,
    stats.epochCredits,
    stats.recCount,
    stats.recVolume,
    stats.verified,
  );
}

/**
 * Locates an account in a reconstructed tree, given the secret and a candidate state.
 *
 * Returns null when that leaf is not in the tree, which is the honest answer to "is this what my
 * account looks like": a caller replaying deltas uses it to confirm each step rather than assuming.
 */
export async function locate(
  snapshot: TreeSnapshot,
  skId: bigint,
  stats: Stats,
  version: bigint,
): Promise<AccountState | null> {
  const leaf = await leafFor(skId, stats, version);
  const index = snapshot.state.indexOf(leaf);
  if (index < 0) return null;
  return {
    skId,
    s: await accountCommitment(skId),
    version,
    stats,
    index,
    path: snapshot.state.pathFor(index),
    nextNullifier: await nullRep(skId, version),
  };
}

/**
 * The block an account's genesis leaf was inserted at — where a deal scan should start.
 *
 * Scanning for your own deals means recomputing `dealSubject` against every activation, because a
 * subject is indistinguishable to anyone without the secret: no indexer can narrow it for you, which
 * is the privacy model working in its least convenient direction. What CAN narrow it is that your
 * deals postdate your registration, and your registration is findable from the secret alone — the
 * genesis leaf is computable, and the log says when it landed.
 *
 * Worth saying because the obvious alternative is worse: a token or marker held by a wallet would
 * publish wallet-to-account, which is the exact link §E.3.15 exists to break. The marker already
 * exists and it is the account's own leaf.
 */
export async function registrationBlock(snapshot: TreeSnapshot, skId: bigint): Promise<bigint | null> {
  // A secret registered exactly one genesis: a verified one, or an open one (2026-10-01). Both are
  // computable, so both are looked for.
  for (const verified of [true, false]) {
    const leaf = await leafFor(skId, await genesis(verified), 0n);
    const index = snapshot.state.indexOf(leaf);
    if (index >= 0) return snapshot.insertedAt[index] ?? null;
  }
  return null;
}

const ESCROW_ABI = [
  {
    type: "event",
    name: "Activated",
    inputs: [
      { name: "dealId", type: "bytes32", indexed: false },
      { name: "holder", type: "address", indexed: false },
      { name: "provider", type: "address", indexed: false },
      { name: "controller", type: "address", indexed: false },
      { name: "token", type: "address", indexed: false },
      { name: "principal", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "subjects",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "bytes32" }, { type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

export type OwnDeal = {
  dealId: bigint;
  /** Which seat the secret held. The kernel never knows this; only the secret can tell. */
  side: "holder" | "provider";
  token: bigint;
  principal: bigint;
  subject: bigint;
};

/**
 * Finds the deals a secret took part in, by recomputing the per-deal pseudonym.
 *
 * `dealSubject = Poseidon(sk_id, dealId)` is all the kernel ever stores, and it is unlinkable
 * across deals to anyone without the secret — which is exactly what makes this scan the ONLY way to
 * find your own history, and why it has to be done by the owner rather than served by an indexer.
 */
export async function scanDeals(
  client: PublicClient,
  escrow: Address,
  skId: bigint,
  opts: { fromBlock?: bigint } = {},
): Promise<OwnDeal[]> {
  const logs = await client.getContractEvents({
    address: escrow,
    abi: ESCROW_ABI,
    eventName: "Activated",
    fromBlock: opts.fromBlock ?? 0n,
    toBlock: "latest",
  });

  const mine: OwnDeal[] = [];
  for (const log of logs) {
    const a = log.args as { dealId: `0x${string}`; token: Address; principal: bigint };
    const dealId = BigInt(a.dealId);
    const mySubject = await dealSubject(skId, dealId);
    const [subjectH, subjectP] = (await client.readContract({
      address: escrow,
      abi: ESCROW_ABI,
      functionName: "subjects",
      args: [a.dealId],
    })) as [`0x${string}`, `0x${string}`];

    const side = BigInt(subjectH) === mySubject
      ? ("holder" as const)
      : BigInt(subjectP) === mySubject
        ? ("provider" as const)
        : null;
    if (side === null) continue;
    mine.push({ dealId, side, token: BigInt(a.token), principal: a.principal, subject: mySubject });
  }
  return mine;
}
