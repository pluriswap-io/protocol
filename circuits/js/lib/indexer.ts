// Reads a deployed `PoseidonTree` back into prover-usable state.
//
// The private layer's circuits prove membership of a leaf in a tree the CONTRACT owns. Until this
// existed nothing in the repo could read that tree: `prove.ts` builds every witness from the pinned
// vectors fixture, so the circuits were verifiable but not usable — there was no path from "I hold a
// secret and a dealId" to "here is my proof".
//
// The tree is reconstructible because `insert` is owner-only and emits every leaf in order, so the
// event log IS the leaf set. Reconstruction ends with a check that earns the rest: the root folded
// locally must equal the root the contract reports. If a log was missed, an RPC lied, or the twin
// ever drifts from `PoseidonTree.sol`, the mismatch surfaces here rather than as an unexplained
// proof rejection later.

import type { Address, PublicClient } from "viem";
import { PoseidonTreeState } from "./tree.ts";

export const POSEIDON_TREE_ABI = [
  {
    type: "event",
    name: "LeafInserted",
    inputs: [
      { name: "index", type: "uint256", indexed: true },
      { name: "leaf", type: "bytes32", indexed: false },
      { name: "root", type: "uint256", indexed: false },
    ],
  },
  { type: "function", name: "depth", inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
  { type: "function", name: "root", inputs: [], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "nextIndex", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function",
    name: "isKnownRoot",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isSpent",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

export type TreeSnapshot = {
  address: Address;
  depth: number;
  /** The leaves in insert order — index i is the leaf at tree index i. */
  leaves: bigint[];
  /** Block each leaf was inserted at, by tree index. An owner's own leaf is the only marker they
   *  need to bound a later scan, and it costs nothing to carry: the log already says it. */
  insertedAt: bigint[];
  /** Folded locally from those leaves; equal to `onChainRoot` or reconstruction threw. */
  state: PoseidonTreeState;
  onChainRoot: bigint;
  /** Block the snapshot was taken at, so a caller can detect drift without re-reading. */
  blockNumber: bigint;
};

export class TreeReconstructionError extends Error {}

/**
 * Rebuilds a tree from its own event log and proves the rebuild against the contract.
 *
 * `fromBlock` matters on a chain with history: an RPC that caps `eth_getLogs` ranges will silently
 * return a window rather than everything, and a missing leaf produces a wrong root — which is
 * exactly what the final check catches. Pass the tree's deployment block when you know it.
 */
export async function readTree(
  client: PublicClient,
  address: Address,
  opts: { fromBlock?: bigint } = {},
): Promise<TreeSnapshot> {
  const [depth, onChainRootHex, nextIndex, blockNumber] = await Promise.all([
    client.readContract({ address, abi: POSEIDON_TREE_ABI, functionName: "depth" }),
    client.readContract({ address, abi: POSEIDON_TREE_ABI, functionName: "root" }),
    client.readContract({ address, abi: POSEIDON_TREE_ABI, functionName: "nextIndex" }),
    client.getBlockNumber(),
  ]);

  const logs = await client.getContractEvents({
    address,
    abi: POSEIDON_TREE_ABI,
    eventName: "LeafInserted",
    fromBlock: opts.fromBlock ?? 0n,
    toBlock: blockNumber,
  });

  const byIndex = new Map<bigint, { leaf: bigint; block: bigint }>();
  for (const log of logs) {
    const { index, leaf } = log.args as { index: bigint; leaf: `0x${string}` };
    byIndex.set(index, { leaf: BigInt(leaf), block: log.blockNumber ?? 0n });
  }

  if (BigInt(byIndex.size) !== nextIndex) {
    throw new TreeReconstructionError(
      `tree ${address}: the log holds ${byIndex.size} leaves, the contract counts ${nextIndex}. ` +
        "An RPC that caps getLogs ranges will do this; pass `fromBlock`.",
    );
  }

  const leaves: bigint[] = [];
  const insertedAt: bigint[] = [];
  for (let i = 0n; i < nextIndex; i++) {
    const row = byIndex.get(i);
    if (row === undefined) throw new TreeReconstructionError(`tree ${address}: no leaf at index ${i}`);
    leaves.push(row.leaf);
    insertedAt.push(row.block);
  }

  const state = await PoseidonTreeState.from(Number(depth), leaves);
  const onChainRoot = BigInt(onChainRootHex);
  if (state.root() !== onChainRoot) {
    throw new TreeReconstructionError(
      `tree ${address}: folded root ${state.root()} != contract root ${onChainRoot}. ` +
        "The JS twin and PoseidonTree.sol disagree, or the log is incomplete.",
    );
  }

  return { address, depth: Number(depth), leaves, insertedAt, state, onChainRoot, blockNumber };
}

/** True while the contract still accepts this root — the window a proof has to land in. */
export async function isRootLive(client: PublicClient, address: Address, root: bigint): Promise<boolean> {
  return client.readContract({
    address,
    abi: POSEIDON_TREE_ABI,
    functionName: "isKnownRoot",
    args: [`0x${root.toString(16).padStart(64, "0")}` as `0x${string}`],
  });
}

/** True once a nullifier has been burned: a spent version, or a spent note. */
export async function isSpent(client: PublicClient, address: Address, nullifier: bigint): Promise<boolean> {
  return client.readContract({
    address,
    abi: POSEIDON_TREE_ABI,
    functionName: "isSpent",
    args: [`0x${nullifier.toString(16).padStart(64, "0")}` as `0x${string}`],
  });
}
