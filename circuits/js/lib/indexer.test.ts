// Runs against a chain when one is offered, and skips otherwise -- the same shape as the real-bb
// tests. `script/e2e.sh` points it at the anvil it just built, which is where it earns its keep:
// that chain has a real accounts tree with real leaves in it.
import { describe, expect, test } from "bun:test";
import { createPublicClient, http, type Address } from "viem";
import { readTree, isRootLive, isSpent, TreeReconstructionError } from "./indexer.ts";
import { foldPath } from "./tree.ts";

const RPC = process.env.PLURI_RPC;
const TREE = process.env.PLURI_TREE as Address | undefined;
const live = Boolean(RPC && TREE);

describe("readTree", () => {
  test.skipIf(!live)("rebuilds the contract's tree from its own log", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snap = await readTree(client, TREE!);

    // The check that makes everything after it trustworthy.
    expect(snap.state.root()).toBe(snap.onChainRoot);
    expect(snap.leaves.length).toBe(snap.state.size);
    expect(snap.depth).toBeGreaterThan(0);
  });

  test.skipIf(!live)("every leaf in it proves against the current root", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snap = await readTree(client, TREE!);
    expect(snap.leaves.length).toBeGreaterThan(0);
    for (let i = 0; i < snap.leaves.length; i++) {
      expect(await foldPath(snap.state.pathFor(i))).toBe(snap.onChainRoot);
    }
  });

  test.skipIf(!live)("the current root is one the contract still accepts", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snap = await readTree(client, TREE!);
    expect(await isRootLive(client, TREE!, snap.onChainRoot)).toBe(true);
    expect(await isRootLive(client, TREE!, 123456789n)).toBe(false);
  });

  test.skipIf(!live)("a nullifier nobody burned reads as unspent", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    expect(await isSpent(client, TREE!, 987654321n)).toBe(false);
  });

  test.skipIf(!live)("a truncated log is caught, not folded into a wrong root", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snap = await readTree(client, TREE!);
    if (snap.leaves.length === 0) return;
    // Past every insert, so the window holds nothing while the contract still counts leaves. An RPC
    // that caps getLogs ranges produces exactly this shape, and it must fail loudly rather than fold
    // a wrong root that would only surface later as an unexplained proof rejection.
    await expect(readTree(client, TREE!, { fromBlock: snap.blockNumber + 1n })).rejects.toThrow(
      TreeReconstructionError,
    );
  });
});
