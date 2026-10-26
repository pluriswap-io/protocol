// One private deal on a live chain, every proof fresh (PROTOCOLO.md §E.3.15.3-§E.3.15.6).
//
// The real-proof tests replay the committed fixtures, and those are pinned to a synthetic token and a
// trusted counterparty: they cannot run on a chain. This script proves against what the chain holds right
// now, with the pinned toolchain (circuits/README.md), and walks the whole private lifecycle between two
// accounts:
//
//   enroll     two anchors in the HumanityRegistry (the mock decoder's admin gives them a score)
//   register   register_humanity + register_account per account (hsk == sk_id, as prepare_side requires)
//   deposit    a bond note per account (deposit)
//   activate   one bonded deal through the kernel, both sides' prepare_side proofs in PackageData
//   terminal   markFiat by the Provider, release by the Holder: Peaceful; the kernel unlocks both locks
//   claim      the terminal delta per account (claim)
//   reabsorb   each released lock back into a note (reabsorb)
//
// What it leaves is an account with a closed deal, a credited counterparty and bond notes, which is what a
// restore from the secret and the chain needs to be tested against (platform LABS-88).
//
// Usage (Arbitrum Sepolia, the private stack of deployments/sepolia-private.json):
//   RPC_URL=https://sepolia-rollup.arbitrum.io/rpc \
//   FUNDER_KEY=0x… HOLDER_KEY=0x… PROVIDER_KEY=0x… \
//   SK_HOLDER=<field> SK_PROVIDER=<field> \
//   bun script/js/private-deal.ts [state.json]
//
// FUNDER_KEY is the admin of the mock decoder and pays the anchors' gas. The anchors are fresh keys kept in
// the state file, which also records every step so a rerun resumes where the last one stopped. The state file
// holds private keys: keep it out of the repository.

import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  type Address,
  type Hex,
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  toHex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import * as c from "../../circuits/js/lib/commitments.ts";
import { modP } from "../../circuits/js/lib/fields.ts";
import { poseidon2 } from "../../circuits/js/lib/poseidon.ts";
import { readTree } from "../../circuits/js/lib/indexer.ts";
import { SparseTree, indexOf } from "../../circuits/js/lib/sparse.ts";
import { depositNote, reabsorb, split } from "../../circuits/js/lib/notes.ts";

const REPO = join(import.meta.dir, "../..");
const CIRCUITS = join(REPO, "circuits");
const BIN = process.env.PLURI_ZK_BIN ?? join(process.env.HOME ?? "", ".pluri-zk/bin");

const RPC = process.env.RPC_URL ?? "https://sepolia-rollup.arbitrum.io/rpc";
const STATE_PATH = process.argv[2] ?? join(REPO, "broadcast/private-deal-state.json");
const layer = JSON.parse(readFileSync(join(REPO, "deployments/sepolia-private.json"), "utf8"));
const packages = JSON.parse(readFileSync(join(REPO, "deployments/sepolia-packages.json"), "utf8"));
const TOKEN: Address = packages.testToken;

const DEPOSIT = 50_000_000n; // 50 TUSD per account: the bond
const PRINCIPAL = 250_000_000n; // one lot (250 TUSD): the minimum the reputation package admits
const LOCK = (PRINCIPAL + 9n) / 10n; // §E.3.14.5
const DECIMALS = 6n;

// ---------------------------------------------------------------- chain

const client = createPublicClient({ chain: arbitrumSepolia, transport: http(RPC) });
const wallet = (key: Hex) => createWalletClient({ account: privateKeyToAccount(key), chain: arbitrumSepolia, transport: http(RPC) });

const ABI = parseAbi([
  "function setScore(address user, uint256 score, uint64 expirationTime)",
  "function enroll(bytes32 identityCommitment)",
  "function enrolled(address anchor) view returns (bool)",
  "function identityCommitmentOf(bytes32 hsk) view returns (bytes32)",
  "function register(bytes proof, bytes32 hn)",
  "function registeredHn(bytes32 hn) view returns (bool)",
  "function humanitySpent(bytes32 hn) view returns (bool)",
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function deposit(address token, uint256 amount, bytes32 note, bytes proof)",
  "function bondRoot() view returns (bytes32)",
  "function domainSeparator() view returns (bytes32)",
  "function activationBps() view returns (uint16)",
  "function status(bytes32 dealId) view returns (uint8)",
  "function markFiat(bytes32 dealId)",
  "function release(bytes32 dealId)",
  "function packageId() view returns (bytes32)",
  "function creditable(bytes32 dealId) view returns (bool)",
  "function pending(bytes32 subject) view returns (uint8 kind, address token, uint256 principal)",
  "function claimed(bytes32 subject) view returns (bool)",
  "function claim(bytes32 dealId, bytes32 dealSubject, bytes32 newLeaf, bytes32 nullRep, bytes32 repRoot, bytes proof)",
  "function lockOf(bytes32 dealId, bytes32 subject) view returns (address token, uint256 amount, bytes32 lockCommit, bool released)",
  "function cutOf(bytes32 dealId, bytes32 subject) view returns (uint256)",
  "function reabsorb(bytes32 dealId, bytes32 dealSubject, bytes32 newNote, bytes32 nullBond, bytes proof)",
]);
const REGISTER_ACCOUNT_ABI = parseAbi(["function register(bytes proof, bytes32 hn, bytes32 leaf0)"]);

const DEAL_TERMS = "(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)";
const ACTIVATE_ABI = parseAbi([
  "struct DealTerms { address holder; address controller; address provider; address token; uint256 principal; uint256 fiatDuration; uint256 releaseDuration; uint256 disputeDuration; uint256 arbitrationDuration; bytes32 fiatCommit; bytes32[] packageIds; }",
  "struct Consent { DealTerms terms; uint256 nonce; uint256 deadline; }",
  "struct PackageMods { address passport; address reputation; address bonds; address zk; address court; }",
  "struct PackageData { bytes holder; bytes provider; bytes court; }",
  "function activate(Consent ha, bytes holderSig, Consent pa, bytes providerSig, Consent ca, bytes controllerSig, PackageMods mods, PackageData data) returns (bytes32)",
]);

async function send(key: Hex, address: Address, functionName: string, args: unknown[], abi: readonly unknown[] = ABI): Promise<void> {
  const w = wallet(key);
  const { request } = await client.simulateContract({ account: w.account, address, abi: abi as never, functionName: functionName as never, args: args as never });
  const hash = await w.writeContract(request as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  console.log(`  ${functionName} ${hash} (gas ${receipt.gasUsed})`);
}

const read = <T>(address: Address, functionName: string, args: unknown[] = []) =>
  client.readContract({ address, abi: ABI, functionName: functionName as never, args: args as never }) as Promise<T>;

const b32 = (x: bigint): Hex => toHex(x, { size: 32 });

// ---------------------------------------------------------------- proving

/** Witness with nargo, prove with bb: the blob an adapter splits (proof || public inputs). */
function prove(circuit: string, inputs: Record<string, unknown>): Hex {
  const env = { ...process.env, PATH: `${BIN}:${process.env.PATH ?? ""}` };
  const run = (cwd: string, cmd: string) => execSync(cmd, { cwd, env, stdio: ["ignore", "pipe", "pipe"] }).toString();
  const crate = join(CIRCUITS, "crates", circuit);
  const prover = "Prover_live";
  const lines = Object.entries(inputs).map(([k, v]) => `${k} = ${toml(v)}`);
  writeFileSync(join(crate, `${prover}.toml`), lines.join("\n") + "\n");
  const work = join(CIRCUITS, "target", "live");
  mkdirSync(work, { recursive: true });
  try {
    run(crate, `nargo execute -p ${prover} live_${circuit}`);
  } finally {
    rmSync(join(crate, `${prover}.toml`), { force: true });
  }
  const bytecode = join(CIRCUITS, "target", `${circuit}.json`);
  const vk = join(work, `${circuit}_vk`);
  if (!existsSync(join(vk, "vk"))) run(CIRCUITS, `bb write_vk -b ${bytecode} -o ${vk} -t evm`);
  const out = join(work, `${circuit}_proof`);
  run(CIRCUITS, `bb prove -b ${bytecode} -w ${join(CIRCUITS, "target", `live_${circuit}.gz`)} -k ${join(vk, "vk")} -o ${out} -t evm`);
  const ok = run(CIRCUITS, `bb verify -k ${join(vk, "vk")} -p ${join(out, "proof")} -i ${join(out, "public_inputs")} -t evm 2>&1`);
  if (!ok.includes("Proof verified successfully")) throw new Error(`${circuit}: bb verify failed`);
  const blob = Buffer.concat([readFileSync(join(out, "proof")), readFileSync(join(out, "public_inputs"))]);
  return `0x${blob.toString("hex")}`;
}

function toml(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(toml).join(", ")}]`;
  if (typeof v === "number") return String(v);
  return `"${modP(BigInt(v as bigint | string)).toString()}"`;
}

// ---------------------------------------------------------------- state

type Side = {
  key: Hex;
  anchorKey: Hex;
  sk: string;
  depositIndex: string;
  steps: Record<string, boolean>;
};
type State = { holder: Side; provider: Side; deal?: { id: Hex; pairSecret: string; terms: unknown; nonce: string }; steps: Record<string, boolean> };

function loadState(): State {
  if (existsSync(STATE_PATH)) return JSON.parse(readFileSync(STATE_PATH, "utf8"));
  const side = (key: string | undefined, sk: string | undefined): Side => {
    if (!key || !sk) throw new Error("HOLDER_KEY, PROVIDER_KEY, SK_HOLDER and SK_PROVIDER are required on the first run");
    return { key: key as Hex, anchorKey: generatePrivateKey(), sk: modP(BigInt(sk)).toString(), depositIndex: "0", steps: {} };
  };
  return { holder: side(process.env.HOLDER_KEY, process.env.SK_HOLDER), provider: side(process.env.PROVIDER_KEY, process.env.SK_PROVIDER), steps: {} };
}

function saveState(s: State): void {
  mkdirSync(join(STATE_PATH, ".."), { recursive: true });
  writeFileSync(STATE_PATH, JSON.stringify(s, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2), { mode: 0o600 });
}

// ---------------------------------------------------------------- steps

const REGISTRY_ID = modP(BigInt(layer.registryId));
const FUNDER = process.env.FUNDER_KEY as Hex;

async function enroll(name: string, side: Side): Promise<void> {
  if (side.steps.enroll) return;
  const anchor = privateKeyToAccount(side.anchorKey).address;
  console.log(`enroll ${name}: anchor ${anchor}`);
  if (!(await read<boolean>(layer.humanityRegistry, "enrolled", [anchor]))) {
    const balance = await client.getBalance({ address: anchor });
    if (balance < 300_000_000_000_000n) {
      const hash = await wallet(FUNDER).sendTransaction({ to: anchor, value: 300_000_000_000_000n });
      await client.waitForTransactionReceipt({ hash });
    }
    const expiry = BigInt(Math.floor(Date.now() / 1000) + 30 * 86400);
    await send(FUNDER, layer.passportDecoder, "setScore", [anchor, 200_000n, expiry]);
    const commitment = await read<Hex>(layer.humanityRegistry, "identityCommitmentOf", [b32(BigInt(side.sk))]);
    await send(side.anchorKey, layer.humanityRegistry, "enroll", [commitment]);
  }
  side.steps.enroll = true;
}

async function register(name: string, side: Side): Promise<void> {
  if (side.steps.register) return;
  const sk = BigInt(side.sk);
  const hn = await poseidon2(sk, REGISTRY_ID);
  console.log(`register ${name}`);
  if (!(await read<boolean>(layer.privateReputation, "registeredHn", [b32(hn)]))) {
    const tree = await readTree(client, layer.enrollmentTree, { fromBlock: BigInt(process.env.FROM_BLOCK ?? "322233838") });
    const index = tree.state.indexOf(await c.accountCommitment(sk));
    if (index < 0) throw new Error("the identity commitment is not in the enrollment tree");
    const path = tree.state.pathFor(index);
    if (!(await read<boolean>(layer.privatePassport, "humanitySpent", [b32(hn)]))) {
      const proof = prove("register_humanity", { h_n: hn, root: path.root, registry_id: REGISTRY_ID, hsk: sk, siblings: path.siblings, indices: path.indices });
      await send(side.key, layer.privatePassport, "register", [proof, b32(hn)]);
    }
    const leaf0 = await leafAt(sk, await genesisStats(), 0n);
    const proof = prove("register_account", { h_n: hn, leaf0, registry_id: REGISTRY_ID, verified: 1n, hsk: sk, sk_id: sk });
    await send(side.key, layer.privateReputation, "register", [proof, b32(hn), b32(leaf0)], REGISTER_ACCOUNT_ABI);
  }
  side.steps.register = true;
}

async function deposit(name: string, side: Side): Promise<void> {
  if (side.steps.deposit) return;
  const sk = BigInt(side.sk);
  const owner = privateKeyToAccount(side.key).address;
  console.log(`deposit ${name}: ${DEPOSIT}`);
  const note = await depositNote(sk, BigInt(TOKEN), DEPOSIT, BigInt(side.depositIndex));
  const proof = prove("deposit", { token: BigInt(TOKEN), amount: DEPOSIT, note: note.commitment, sk_id: sk, index: BigInt(side.depositIndex) });
  await send(side.key, TOKEN, "mint", [owner, DEPOSIT]);
  await send(side.key, TOKEN, "approve", [layer.privateBondVault, DEPOSIT]);
  await send(side.key, layer.privateBondVault, "deposit", [TOKEN, DEPOSIT, b32(note.commitment), proof]);
  side.steps.deposit = true;
}

type Stats = {
  count: bigint; volume: bigint; penalty: bigint; inFlight: bigint; token: bigint; cpRoot: bigint;
  epoch: bigint; epochCredits: bigint; recCount: bigint; recVolume: bigint; verified: bigint;
};

async function genesisStats(): Promise<Stats> {
  const cp = await SparseTree.create(c.CP_DEPTH);
  return { count: 0n, volume: 0n, penalty: 0n, inFlight: 0n, token: 0n, cpRoot: cp.emptyRoot(), epoch: 0n, epochCredits: 0n, recCount: 0n, recVolume: 0n, verified: 1n };
}

async function leafAt(sk: bigint, s: Stats, version: bigint): Promise<bigint> {
  return c.leafRep(await c.accountCommitment(sk), s.count, s.volume, s.penalty, s.inFlight, s.token, await c.leafSalt(sk, version), version, s.cpRoot, s.epoch, s.epochCredits, s.recCount, s.recVolume, s.verified);
}

function termsOf(s: State, packageIds: Hex[]) {
  return {
    holder: privateKeyToAccount(s.holder.key).address,
    controller: privateKeyToAccount(s.holder.key).address,
    provider: privateKeyToAccount(s.provider.key).address,
    token: TOKEN,
    principal: PRINCIPAL,
    fiatDuration: 3600n,
    releaseDuration: 1800n,
    disputeDuration: 7200n,
    arbitrationDuration: 0n,
    fiatCommit: keccak256(toHex("pluri:live-deal:fiat")),
    packageIds,
  };
}

const TYPES = {
  DealTerms: [
    { name: "holder", type: "address" },
    { name: "controller", type: "address" },
    { name: "provider", type: "address" },
    { name: "token", type: "address" },
    { name: "principal", type: "uint256" },
    { name: "fiatDuration", type: "uint256" },
    { name: "releaseDuration", type: "uint256" },
    { name: "disputeDuration", type: "uint256" },
    { name: "arbitrationDuration", type: "uint256" },
    { name: "fiatCommit", type: "bytes32" },
    { name: "packageIds", type: "bytes32[]" },
  ],
} as const;

function dealTermsHash(t: ReturnType<typeof termsOf>): Hex {
  const typehash = keccak256(toHex(`DealTerms${DEAL_TERMS}`));
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes32" }, { type: "bytes32" }],
      [typehash, t.holder, t.controller, t.provider, t.token, t.principal, t.fiatDuration, t.releaseDuration, t.disputeDuration, t.arbitrationDuration, t.fiatCommit, keccak256(`0x${t.packageIds.map((x) => x.slice(2)).join("")}`)],
    ),
  );
}

async function activate(s: State): Promise<void> {
  if (s.steps.activate) return;
  console.log("activate");
  const ids = [layer.passportId as Hex, (await read<Hex>(layer.privateReputation, "packageId")) as Hex, layer.bondsId as Hex].sort((a, b) =>
    BigInt(a) < BigInt(b) ? -1 : 1,
  );
  const terms = termsOf(s, ids);
  const nonce = s.deal?.nonce ? BigInt(s.deal.nonce) : BigInt(keccak256(toHex(`pluri:live-deal:${Date.now()}`))) >> 64n;
  const domain = await read<Hex>(layer.escrow, "domainSeparator");
  const dealId = keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [domain, dealTermsHash(terms), nonce, nonce, 0n]),
  );
  const pairSecret = s.deal?.pairSecret ? BigInt(s.deal.pairSecret) : modP(BigInt(keccak256(toHex(`pluri:live-deal:k:${dealId}`))));
  s.deal = { id: dealId, pairSecret: pairSecret.toString(), terms, nonce: nonce.toString() };
  saveState(s);

  const did = BigInt(dealId);
  const skH = BigInt(s.holder.sk);
  const skP = BigInt(s.provider.sk);
  const sH = await c.accountCommitment(skH);
  const sP = await c.accountCommitment(skP);
  const pairTag = await c.pairTag(sH, sP, did, pairSecret);
  const fromBlock = BigInt(process.env.FROM_BLOCK ?? "322233838");
  const accounts = await readTree(client, layer.accountTree, { fromBlock });
  const notes = await readTree(client, layer.notesTree, { fromBlock });

  const side = async (sk: bigint, sOther: bigint, depositIndex: bigint) => {
    const g = await genesisStats();
    const leaf = await leafAt(sk, g, 0n);
    const rep = accounts.state.pathFor(accounts.state.indexOf(leaf));
    const newLeaf = await leafAt(sk, { ...g, inFlight: PRINCIPAL, token: BigInt(TOKEN) }, 1n);
    const note = await depositNote(sk, BigInt(TOKEN), DEPOSIT, depositIndex);
    const noteIndex = notes.state.indexOf(note.commitment);
    if (noteIndex < 0) throw new Error("the deposit note is not in the notes tree");
    const np = notes.state.pathFor(noteIndex);
    const { lock, change } = await split(sk, note, did, LOCK);
    const subject = await c.dealSubject(sk, did);
    const hintS = modP(sOther + (await c.hintKey(sk, did, 1n)));
    const hintK = modP(pairSecret + (await c.hintKey(sk, did, 2n)));
    const nullRep = await c.nullRep(sk, 0n);
    const proof = prove("prepare_side", {
      subject, deal_id: did, token: BigInt(TOKEN), principal: PRINCIPAL, decimals: DECIMALS,
      rep_root: accounts.state.root(), new_leaf: newLeaf, nullifier: nullRep, pair_tag: pairTag,
      lock_commit: lock.commitment, lock_amount: LOCK, change_note: change!.commitment, null_bond_out: note.nullifier,
      bond_root: notes.state.root(), registry_id: REGISTRY_ID, hint_s: hintS, hint_k: hintK, arbiters: [0n, 0n, 0n], verified: 1n,
      sk_id: sk, s_other: sOther, pair_secret: pairSecret,
      count: 0n, volume: 0n, penalty: 0n, in_flight: 0n, leaf_token: 0n, version: 0n, cp_root: g.cpRoot, epoch: 0n, epoch_credits: 0n,
      rec_count: 0n, rec_volume: 0n, rep_siblings: rep.siblings, rep_indices: rep.indices,
      source_salt: note.salt, note_amount: DEPOSIT, note_siblings: np.siblings, note_indices: np.indices,
    });
    const inputs = {
      dealSubject: b32(subject), dealId, token: TOKEN, principal: PRINCIPAL, repRoot: b32(accounts.state.root()), newLeaf: b32(newLeaf),
      nullRep: b32(nullRep), pairTag: b32(pairTag), lockCommit: b32(lock.commitment), lockAmount: LOCK, changeNote: b32(change!.commitment),
      nullBond: b32(note.nullifier), bondRoot: b32(notes.state.root()), registryId: layer.registryId as Hex, hintS: b32(hintS), hintK: b32(hintK),
      arbiters: [b32(0n), b32(0n), b32(0n)] as const, verified: true,
    };
    return encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "dealSubject", type: "bytes32" }, { name: "dealId", type: "bytes32" }, { name: "token", type: "address" }, { name: "principal", type: "uint256" },
            { name: "repRoot", type: "bytes32" }, { name: "newLeaf", type: "bytes32" }, { name: "nullRep", type: "bytes32" }, { name: "pairTag", type: "bytes32" },
            { name: "lockCommit", type: "bytes32" }, { name: "lockAmount", type: "uint256" }, { name: "changeNote", type: "bytes32" }, { name: "nullBond", type: "bytes32" },
            { name: "bondRoot", type: "bytes32" }, { name: "registryId", type: "bytes32" }, { name: "hintS", type: "bytes32" }, { name: "hintK", type: "bytes32" },
            { name: "arbiters", type: "bytes32[3]" }, { name: "verified", type: "bool" },
          ],
        },
        { type: "bytes" },
      ],
      [inputs, proof],
    );
  };

  console.log("  proving the holder's side");
  const holderData = await side(skH, sP, BigInt(s.holder.depositIndex));
  console.log("  proving the provider's side");
  const providerData = await side(skP, sH, BigInt(s.provider.depositIndex));

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const domainArgs = { name: "PluriSwap", version: "2", chainId: arbitrumSepolia.id, verifyingContract: layer.escrow as Address };
  const sign = (key: Hex, primaryType: "HolderAuthorization" | "ProviderAgreement") =>
    privateKeyToAccount(key).signTypedData({
      domain: domainArgs,
      types: { ...TYPES, [primaryType]: [{ name: "terms", type: "DealTerms" }, { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" }] },
      primaryType,
      message: { terms, nonce, deadline },
    } as never);
  const ha = { terms, nonce, deadline };
  const pa = { terms, nonce, deadline };
  // The Holder is the controller: no controller consent, an all-zero acceptance.
  const zero = "0x0000000000000000000000000000000000000000" as Address;
  const ca = {
    terms: { holder: zero, controller: zero, provider: zero, token: zero, principal: 0n, fiatDuration: 0n, releaseDuration: 0n, disputeDuration: 0n, arbitrationDuration: 0n, fiatCommit: b32(0n), packageIds: [] as Hex[] },
    nonce: 0n,
    deadline: 0n,
  };
  const holderSig = await sign(s.holder.key, "HolderAuthorization");
  const providerSig = await sign(s.provider.key, "ProviderAgreement");

  // The kernel pulls the principal plus its activation fee from the Holder.
  const bps = BigInt(await read<number>(layer.escrow, "activationBps"));
  const pull = PRINCIPAL + (PRINCIPAL * bps) / 10_000n;
  const holder = privateKeyToAccount(s.holder.key).address;
  await send(s.holder.key, TOKEN, "mint", [holder, pull]);
  await send(s.holder.key, TOKEN, "approve", [layer.escrow, pull]);

  const mods = { passport: layer.privatePassport, reputation: layer.privateReputation, bonds: layer.privateBondVault, zk: "0x0000000000000000000000000000000000000000", court: "0x0000000000000000000000000000000000000000" };
  await send(s.holder.key, layer.escrow, "activate", [ha, holderSig, pa, providerSig, ca, "0x", mods, { holder: holderData, provider: providerData, court: "0x" }], ACTIVATE_ABI);
  s.steps.activate = true;
}

async function terminal(s: State): Promise<void> {
  if (s.steps.terminal) return;
  console.log("terminal: markFiat, release");
  await send(s.provider.key, layer.escrow, "markFiat", [s.deal!.id]);
  await send(s.holder.key, layer.escrow, "release", [s.deal!.id]);
  s.steps.terminal = true;
}

async function claimSide(name: string, s: State, side: Side, other: Side): Promise<void> {
  if (side.steps.claim) return;
  console.log(`claim ${name}`);
  const sk = BigInt(side.sk);
  const did = BigInt(s.deal!.id);
  const subject = await c.dealSubject(sk, did);
  const [kind, , principal] = await read<[number, Address, bigint]>(layer.privateReputation, "pending", [b32(subject)]);
  const credit = await read<boolean>(layer.privateReputation, "creditable", [s.deal!.id]);
  const sOther = await c.accountCommitment(BigInt(other.sk));
  const pairSecret = BigInt(s.deal!.pairSecret);
  const g = await genesisStats();
  const current = { ...g, inFlight: principal, token: BigInt(TOKEN) };
  const leaf = await leafAt(sk, current, 1n);
  const accounts = await readTree(client, layer.accountTree, { fromBlock: BigInt(process.env.FROM_BLOCK ?? "322233838") });
  const index = accounts.state.indexOf(leaf);
  if (index < 0) throw new Error("the admitted leaf is not in the account tree");
  const rep = accounts.state.pathFor(index);
  const cp = await SparseTree.create(c.CP_DEPTH);
  const cpPath = await cp.pathFor(indexOf(await c.cpPath(sOther)));
  // The adapter reads the epoch from the claim's block: a day boundary between proving and landing fails it.
  const epoch = BigInt(Math.floor(Date.now() / 1000 / 86400));
  const credits = kind === 0 && credit ? 1n : 0n;
  const takenTree = await SparseTree.create(c.CP_DEPTH);
  takenTree.set(indexOf(await c.cpPath(sOther)), sOther);
  const next = {
    ...current,
    count: credits,
    volume: credits * principal,
    inFlight: 0n,
    cpRoot: credits === 1n ? await takenTree.root() : g.cpRoot,
    epoch,
    epochCredits: credits,
    recCount: kind === 0 ? 1n : 0n,
    recVolume: kind === 0 ? principal : 0n,
    penalty: [0n, 0n, 5n, 0n, 15n, 10n, 5n][kind]!,
  };
  const newLeaf = await leafAt(sk, next, 2n);
  const nullRep = await c.nullRep(sk, 1n);
  const proof = prove("claim", {
    deal_id: did, subject, new_leaf: newLeaf, nullifier: nullRep, kind: BigInt(kind), token: BigInt(TOKEN), principal, rep_root: rep.root,
    pair_tag: await c.pairTag(await c.accountCommitment(sk), sOther, did, pairSecret), epoch, credit: credit ? 1n : 0n,
    sk_id: sk, count: 0n, volume: 0n, penalty: 0n, in_flight: principal, leaf_token: BigInt(TOKEN), version: 1n, cp_root: g.cpRoot,
    leaf_epoch: 0n, leaf_credits: 0n, rec_count: 0n, rec_volume: 0n, verified: 1n, s_other: sOther, pair_secret: pairSecret, slot: 0n,
    cp_siblings: cpPath.siblings, siblings: rep.siblings, indices: rep.indices,
  });
  await send(side.key, layer.privateReputation, "claim", [s.deal!.id, b32(subject), b32(newLeaf), b32(nullRep), b32(rep.root), proof]);
  side.steps.claim = true;
}

async function reabsorbSide(name: string, s: State, side: Side): Promise<void> {
  if (side.steps.reabsorb) return;
  console.log(`reabsorb ${name}`);
  const sk = BigInt(side.sk);
  const did = BigInt(s.deal!.id);
  const subject = await c.dealSubject(sk, did);
  const [, amount, lockCommit, released] = await read<[Address, bigint, Hex, boolean]>(layer.privateBondVault, "lockOf", [s.deal!.id, b32(subject)]);
  if (!released) throw new Error("the lock is not released");
  const cut = await read<bigint>(layer.privateBondVault, "cutOf", [s.deal!.id, b32(subject)]);
  const note = await depositNote(sk, BigInt(TOKEN), DEPOSIT, BigInt(side.depositIndex));
  const { lock } = await split(sk, note, did, amount);
  if (b32(lock.commitment) !== lockCommit.toLowerCase()) throw new Error("the lock on chain is not this account's split");
  const merged = await reabsorb(sk, lock, amount - cut);
  const proof = prove("reabsorb", {
    deal_id: did, subject, token: BigInt(TOKEN), amount, kept: amount - cut, lock_commit: lock.commitment, new_note: merged.commitment,
    nullifier: lock.nullifier, sk_id: sk,
  });
  await send(side.key, layer.privateBondVault, "reabsorb", [s.deal!.id, b32(subject), b32(merged.commitment), b32(lock.nullifier), proof]);
  side.steps.reabsorb = true;
}

async function main() {
  if (!FUNDER) throw new Error("FUNDER_KEY is required");
  const s = loadState();
  saveState(s);
  const step = async (f: () => Promise<void>) => {
    await f();
    saveState(s);
  };
  await step(() => enroll("holder", s.holder));
  await step(() => enroll("provider", s.provider));
  await step(() => register("holder", s.holder));
  await step(() => register("provider", s.provider));
  await step(() => deposit("holder", s.holder));
  await step(() => deposit("provider", s.provider));
  await step(() => activate(s));
  await step(() => terminal(s));
  await step(() => claimSide("holder", s, s.holder, s.provider));
  await step(() => claimSide("provider", s, s.provider, s.holder));
  await step(() => reabsorbSide("holder", s, s.holder));
  await step(() => reabsorbSide("provider", s, s.provider));
  console.log(`done. deal ${s.deal!.id}`);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});

