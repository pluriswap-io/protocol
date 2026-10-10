// The recovery property, against a real chain when one is offered.
//
// `script/e2e.sh` points these at the anvil it just registered an account on, which is the only
// place the claim can actually be tested: a fixture cannot show that a secret finds its leaf in a
// tree a contract owns.
import { describe, expect, test } from "bun:test";
import { createPublicClient, http, type Address } from "viem";
import { readFileSync } from "node:fs";
import { genesis, leafFor, locate, registrationBlock, scanDeals } from "./account.ts";
import { readTree } from "./indexer.ts";
import { foldPath } from "./tree.ts";

const RPC = process.env.PLURI_RPC;
const TREE = process.env.PLURI_TREE as Address | undefined;
const ESCROW = process.env.PLURI_ESCROW as Address | undefined;
const live = Boolean(RPC && TREE);

const vectors = JSON.parse(readFileSync("test/fixtures/vectors.json", "utf8"));
const SK_ID = BigInt(vectors.registry.sk_id ?? vectors.prepare.sk_id);

describe("leafFor", () => {
  test("rebuilds the registered genesis leaf from the secret alone", async () => {
    expect(await leafFor(SK_ID, await genesis(), 0n)).toBe(BigInt(vectors.registry.sample_leaf0));
  });

  test("a different version is a different leaf, with no stored salt anywhere", async () => {
    expect(await leafFor(SK_ID, await genesis(), 0n)).not.toBe(await leafFor(SK_ID, await genesis(), 1n));
  });

  test("a different secret cannot land on the same leaf", async () => {
    expect(await leafFor(SK_ID + 1n, await genesis(), 0n)).not.toBe(BigInt(vectors.registry.sample_leaf0));
  });
});

describe("locate, against a chain", () => {
  test.skipIf(!live)("the secret finds its own leaf in the contract's tree", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snapshot = await readTree(client, TREE!);
    const state = await locate(snapshot, SK_ID, await genesis(), 0n);

    expect(state).not.toBeNull();
    expect(state!.index).toBe(0);
    expect(state!.version).toBe(0n);
    // And the path it hands back proves against the root the contract reports right now.
    expect(await foldPath(state!.path)).toBe(snapshot.onChainRoot);
  });

  test.skipIf(!live)("a state the account is not in returns null rather than a wrong leaf", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snapshot = await readTree(client, TREE!);
    expect(await locate(snapshot, SK_ID, await genesis(), 7n)).toBeNull();
    expect(await locate(snapshot, SK_ID + 1n, await genesis(), 0n)).toBeNull();
  });

  // The answer to "where do I start looking": the account's own leaf, not a token held by a wallet.
  // A wallet-held marker would publish wallet-to-account, the one link §E.3.15 exists to break.
  test.skipIf(!live)("the secret finds the block its own registration landed in", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    const snapshot = await readTree(client, TREE!);
    const block = await registrationBlock(snapshot, SK_ID);
    expect(block).not.toBeNull();
    expect(block!).toBeGreaterThan(0n);
    expect(block!).toBeLessThanOrEqual(snapshot.blockNumber);
    // A secret with no account on this chain gets null, not a misleading block.
    expect(await registrationBlock(snapshot, SK_ID + 1n)).toBeNull();
  });

  test.skipIf(!(live && ESCROW))("a secret with no deals finds none, and does not throw", async () => {
    const client = createPublicClient({ transport: http(RPC) });
    // The sample account has registered but never activated a private deal.
    const snapshot = await readTree(client, TREE!);
    const from = (await registrationBlock(snapshot, SK_ID)) ?? 0n;
    // Bounded by the registration rather than by genesis: the scan a real client would run.
    expect(await scanDeals(client, ESCROW!, SK_ID, { fromBlock: from })).toEqual([]);
  });
});
