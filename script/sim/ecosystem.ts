// The ecosystem simulation: a population of agents trading against the deployed protocol on anvil.
//
// The unit tests prove that every transition does what it says. They cannot say whether the SYSTEM —
// many people, some honest and some not, choosing counterparties by what the protocol shows them —
// rewards what it claims to reward. This does: it runs the same population through several markets and
// reports, per strategy, who ended up richer and who ended up excluded.
//
// The kernel rules it runs against (Anexo R, 2026-09-24): after a dispute there is no split — only
// all-or-nothing agreements, a cancel (all to the Holder) or a co-signed release (all to the Provider) —
// and a dispute nobody settles in a deal with no tribunal BURNS the principal. So what decides a fight is
// each side's attitude to the burn:
//
//   cheater  rational   gives way once disputed: the liar signs the cancel, the extortionist the release
//            stubborn   never gives way; waits for the victim to hand everything over, or for the burn
//   victim   principled never hands a cheater anything: it would rather burn
//            rational   compares: handing over costs the principal; the burn costs the principal PLUS its
//                       bond and +10 — so it hands over
//
//   A  Core puro                              stubborn cheaters, principled victims
//   B  Oficial sin tribunal · tramposo racional
//   C  Oficial sin tribunal · terco vs víctima firme
//   D  Oficial sin tribunal · terco vs víctima racional
//   E  Oficial con tribunal                   the wronged Holder goes to court; a truthful tribunal decides
//
// Strategies. Holders sell stablecoins for fiat; Providers buy them with fiat.
//   honest        pays when it says it paid; releases when paid (sometimes forgets: the claim path)
//   liar          a Provider who marks fiat sent without paying
//   extortionist  a Holder who is paid, then disputes to claw back half
//
// Every economic number is on chain except the fiat leg, which is a ledger: the protocol never sees
// fiat, and neither does its simulation. 1 token = 1 unit of fiat.
//
// Run: script/sim/run.sh            (anvil + deploy + this)
//      ROUNDS=20 SEED=7 script/sim/run.sh

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  decodeEventLog,
  http,
  keccak256,
  maxUint256,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const REPO = join(import.meta.dir, "../..");
const RPC = process.env.RPC ?? "http://127.0.0.1:8546";
const ROUNDS = Number(process.env.ROUNDS ?? 12);
const SEED = Number(process.env.SEED ?? 1);
const OUT = process.env.SIM_OUT ?? "/tmp/pluriswap-sim.json";

export const UNIT = 1_000_000n; // 6 decimals
export const T = (n: number) => BigInt(Math.round(n * 1e6));
export const fmt = (x: bigint) => (Number(x) / 1e6).toFixed(2);

// Market parameters. Stated, because every one of them is a judgement the result depends on.
export const CORE_DEAL = T(250); // pure Core has no caps, so it trades at the T1 size
export const MAX_DEAL = T(5000); // nobody trades the unbounded T5 column in a 12-round market
export const BOND_DEPOSIT = T(1000); // what each identity parks in the vault
export const SCREEN_PENALTY = 6; // a counterparty refuses penalty band >= 2 (§E.3.15.7): 6+ points
export const IDENTITY_COST = T(25); // what a fresh Passport identity costs a cheater (stamps, time)
export const FORGET_RATE = 0.2; // an honest Holder who does not release, so the Provider claims
export const FIAT_DURATION = 3600n;
export const RELEASE_DURATION = 7200n;
export const DISPUTE_DURATION = 86_400n;
export const ARBITRATION_DURATION = 7n * 86_400n;

// ---------------------------------------------------------------- chain

// anvil mines on submission, so a receipt exists the moment the hash does: poll fast, not every 4s.
export const pub = createPublicClient({ chain: foundry, transport: http(RPC), pollingInterval: 10 });
export const wallet = createWalletClient({ chain: foundry, transport: http(RPC), pollingInterval: 10 });
export const test = createTestClient({ chain: foundry, mode: "anvil", transport: http(RPC) });

export const abi = (name: string) => JSON.parse(readFileSync(join(REPO, "out", `${name}.sol`, `${name}.json`), "utf8")).abi;
export const ESCROW = abi("Escrow");
export const TOKEN = abi("TestToken");
export const PASSPORT = abi("PassportMock");
export const REPUTATION = abi("Reputation");
export const VAULT = abi("BondVault");
export const COURT = abi("ArbitrationMock");

export const dep = JSON.parse(readFileSync(join(REPO, "deployments/31337-packages.json"), "utf8"));
export const escrow = dep.escrow as Address;
export const token = dep.testToken as Address;
export const admin = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

export const gasByVerb = new Map<string, { n: number; gas: bigint }>();

export async function send(account: PrivateKeyAccount | Address, address: Address, a: unknown, fn: string, args: unknown[]) {
  const { request } = await pub.simulateContract({ account, address, abi: a as never, functionName: fn, args } as never);
  const hash = await wallet.writeContract(request as never);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${fn} reverted`);
  const g = gasByVerb.get(fn) ?? { n: 0, gas: 0n };
  gasByVerb.set(fn, { n: g.n + 1, gas: g.gas + receipt.gasUsed });
  return receipt;
}

export const read = (address: Address, a: unknown, fn: string, args: unknown[] = []) =>
  pub.readContract({ address, abi: a as never, functionName: fn, args } as never) as Promise<never>;

export async function warp(seconds: bigint) {
  await test.increaseTime({ seconds: Number(seconds) });
  await test.mine({ blocks: 1 });
}

// ---------------------------------------------------------------- determinism

let rng = SEED >>> 0;
export function rand(): number {
  // mulberry32
  rng = (rng + 0x6d2b79f5) >>> 0;
  let t = rng;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
export const shuffle = <X>(xs: X[]) => {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
};
export const nonce = () => BigInt(keccak256(toHex(`nonce:${rand()}:${Date.now()}:${Math.random()}`))) >> 64n;

// ---------------------------------------------------------------- agents

export type Strategy = "honest" | "liar" | "extortionist";
export type Role = "holder" | "provider";

export interface Identity {
  account: PrivateKeyAccount;
  subject: Hex;
}

export interface Agent {
  name: string;
  role: Role;
  strategy: Strategy;
  ids: Identity[];
  minted: bigint;
  fiatPaid: bigint;
  fiatReceived: bigint;
  identityCost: bigint;
  deals: number;
  idle: number; // rounds with no acceptable counterparty
  outcomes: Record<string, number>;
}

export const cur = (a: Agent) => a.ids[a.ids.length - 1];

export interface Scenario {
  key: string;
  name: string;
  packaged: boolean;
  tribunal: boolean;
  stubborn: boolean; // does a cheater hold out once disputed?
  victimYields: boolean; // does a victim hand a stubborn cheater everything to avoid the burn?
  court?: Address; // a market's own tribunal (tribunal.ts deploys one per accuracy); default: the deployed mock
  courtId?: Hex;
}

const SCENARIOS: Scenario[] = [
  { key: "A", name: "Core puro · terco vs víctima firme", packaged: false, tribunal: false, stubborn: true, victimYields: false },
  { key: "B", name: "Oficial sin tribunal · tramposo racional", packaged: true, tribunal: false, stubborn: false, victimYields: false },
  { key: "C", name: "Oficial sin tribunal · terco vs víctima firme", packaged: true, tribunal: false, stubborn: true, victimYields: false },
  { key: "D", name: "Oficial sin tribunal · terco vs víctima racional", packaged: true, tribunal: false, stubborn: true, victimYields: true },
  { key: "E", name: "Oficial con tribunal", packaged: true, tribunal: true, stubborn: true, victimYields: false },
];

const POPULATION: [Role, Strategy, number][] = [
  ["holder", "honest", 6],
  ["holder", "extortionist", 2],
  ["provider", "honest", 6],
  ["provider", "liar", 2],
];

export async function newIdentity(scn: Scenario, a: Agent): Promise<Identity> {
  const n = a.ids.length;
  const key = keccak256(toHex(`pluriswap-sim:${SEED}:${scn.key}:${a.name}:${n}`));
  const account = privateKeyToAccount(key);
  const subject = keccak256(toHex(`subject:${SEED}:${scn.key}:${a.name}:${n}`));
  await test.setBalance({ address: account.address, value: 10n ** 20n });
  await send(admin, dep.passport, PASSPORT, "setHuman", [account.address, subject]);
  await mint(a, account.address, T(20_000));
  await send(account, token, TOKEN, "approve", [escrow, maxUint256]);
  await send(account, token, TOKEN, "approve", [scn.court ?? dep.arbitration, maxUint256]);
  if (scn.packaged) {
    await send(account, token, TOKEN, "approve", [dep.bondVault, maxUint256]);
    await send(account, dep.bondVault, VAULT, "deposit", [subject, token, BOND_DEPOSIT]);
  }
  return { account, subject };
}

export async function mint(a: Agent, to: Address, amount: bigint) {
  await send(admin, token, TOKEN, "mint", [to, amount]);
  a.minted += amount;
}

/// What an agent is worth right now, across every identity it ever used: tokens in wallets and in the
/// vault, less what it was minted, plus the fiat ledger, less what its identities cost.
export async function worth(scn: Scenario, a: Agent): Promise<bigint> {
  let crypto = 0n;
  for (const id of a.ids) {
    crypto += (await read(token, TOKEN, "balanceOf", [id.account.address])) as bigint;
    if (scn.packaged) {
      const [deposited] = [(await read(dep.bondVault, VAULT, "deposited", [id.subject, token])) as bigint];
      crypto += deposited;
    }
  }
  return crypto - a.minted + a.fiatReceived - a.fiatPaid - a.identityCost;
}

// ---------------------------------------------------------------- reputation, as a counterparty sees it

export async function penaltyOf(scn: Scenario, id: Identity): Promise<number> {
  if (!scn.packaged) return 0;
  const [, penalty] = (await read(dep.reputation, REPUTATION, "stats", [id.subject, token])) as [number, number, bigint];
  return Number(penalty);
}

export async function capOf(scn: Scenario, id: Identity): Promise<bigint> {
  if (!scn.packaged) return CORE_DEAL;
  const c = (await read(dep.reputation, REPUTATION, "cap", [id.subject, token, true])) as bigint;
  return c > MAX_DEAL ? MAX_DEAL : c;
}

export async function acceptable(scn: Scenario, id: Identity) {
  return (await penaltyOf(scn, id)) < SCREEN_PENALTY; // Core shows nothing, so it accepts everyone
}

// ---------------------------------------------------------------- the deal

export const TYPES = {
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
  HolderAuthorization: [
    { name: "terms", type: "DealTerms" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  ProviderAgreement: [
    { name: "terms", type: "DealTerms" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  MutualCancel: [
    { name: "dealId", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  CoSignedRelease: [
    { name: "dealId", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const domain = { name: "PluriSwap", version: "2", chainId: 31337, verifyingContract: escrow };

export function packages(scn: Scenario): { ids: Hex[]; mods: Record<string, Address> } {
  if (!scn.packaged) {
    return { ids: [], mods: { passport: zeroAddress, reputation: zeroAddress, bonds: zeroAddress, zk: zeroAddress, court: zeroAddress } };
  }
  const ids = [dep.passportId, dep.reputationId, dep.bondsId, ...(scn.tribunal ? [scn.courtId ?? dep.arbId] : [])] as Hex[];
  ids.sort((x, y) => (BigInt(x) < BigInt(y) ? -1 : 1));
  return {
    ids,
    mods: {
      passport: dep.passport,
      reputation: dep.reputation,
      bonds: dep.bondVault,
      zk: zeroAddress,
      court: scn.tribunal ? (scn.court ?? dep.arbitration) : zeroAddress,
    },
  };
}

export interface Deal {
  id: Hex;
  holder: Agent;
  provider: Agent;
  principal: bigint;
  paid: boolean; // did fiat actually move?
  disputed: boolean;
  forgot: boolean;
  split: boolean;
  court: boolean;
}

export async function activate(scn: Scenario, h: Agent, p: Agent, principal: bigint): Promise<Deal> {
  const H = cur(h);
  const P = cur(p);
  const { ids, mods } = packages(scn);
  const now = (await pub.getBlock()).timestamp;
  const terms = {
    holder: H.account.address,
    controller: H.account.address,
    provider: P.account.address,
    token,
    principal,
    fiatDuration: FIAT_DURATION,
    releaseDuration: RELEASE_DURATION,
    disputeDuration: DISPUTE_DURATION,
    arbitrationDuration: scn.tribunal ? ARBITRATION_DURATION : 0n,
    fiatCommit: (BigInt(keccak256(toHex(`fiat:${rand()}`))) >> 8n).toString(16).padStart(64, "0"),
    packageIds: ids,
  };
  terms.fiatCommit = `0x${terms.fiatCommit}` as never;
  const ha = { terms, nonce: nonce(), deadline: now + 3600n };
  const pa = { terms, nonce: nonce(), deadline: now + 3600n };
  const hs = await H.account.signTypedData({ domain, types: TYPES, primaryType: "HolderAuthorization", message: ha as never });
  const ps = await P.account.signTypedData({ domain, types: TYPES, primaryType: "ProviderAgreement", message: pa as never });
  const ca = { terms, nonce: 0n, deadline: 0n };
  // Keep the Holder liquid: principal + activation fee + a contest, minted as needed (and accounted).
  const bal = (await read(token, TOKEN, "balanceOf", [H.account.address])) as bigint;
  if (bal < principal + T(50)) await mint(h, H.account.address, principal + T(1000));
  const receipt = await send(admin, escrow, ESCROW, "activate", [ha, hs, pa, ps, ca, "0x", mods]);
  let id: Hex | undefined;
  for (const log of receipt.logs) {
    try {
      const ev = decodeEventLog({ abi: ESCROW, data: log.data, topics: log.topics }) as { eventName: string; args: { dealId: Hex } };
      if (ev.eventName === "Activated") id = ev.args.dealId;
    } catch {}
  }
  if (!id) throw new Error("no Activated event");
  h.deals++;
  p.deals++;
  return { id, holder: h, provider: p, principal, paid: false, disputed: false, forgot: false, split: false, court: false };
}

/// The two all-or-nothing agreements a dispute leaves open, signed by both sides: `toHolder` is the mutual
/// cancel, otherwise the co-signed release.
export async function allOrNothing(d: Deal, toHolder: boolean) {
  const H = cur(d.holder);
  const P = cur(d.provider);
  const deadline = (await pub.getBlock()).timestamp + 3600n;
  const type = toHolder ? "MutualCancel" : "CoSignedRelease";
  const pm = { dealId: d.id, nonce: nonce(), deadline };
  const cm = { dealId: d.id, nonce: nonce(), deadline };
  const psig = await P.account.signTypedData({ domain, types: TYPES, primaryType: type, message: pm as never });
  const csig = await H.account.signTypedData({ domain, types: TYPES, primaryType: type, message: cm as never });
  await send(admin, escrow, ESCROW, toHolder ? "mutualCancel" : "coSignedRelease", [pm, psig, cm, csig]);
  d.split = true; // reused as "settled by agreement after a dispute"
}

export const STATUS = ["NONE", "FUNDED", "FIAT_SENT", "DISPUTED", "RELEASED", "RESOLVED_SPLIT", "STALEMATE", "CANCELLED", "ARBITRATION_ACTIVE", "RESOLVED_BY_ARBITRATION", "CLAIMED", "ABANDONED"];

// ---------------------------------------------------------------- one market

interface Result {
  scenario: Scenario;
  agents: Agent[];
  worth: Map<Agent, bigint>;
  penalty: Map<Agent, number>;
  outcomes: Record<string, number>;
  cheatOutcomes: Record<string, number>;
  unmatchedHonest: number;
}

async function runScenario(scn: Scenario): Promise<Result> {
  const agents: Agent[] = [];
  for (const [role, strategy, n] of POPULATION) {
    for (let i = 0; i < n; i++) {
      const a: Agent = {
        name: `${strategy}-${role}-${i}`,
        role,
        strategy,
        ids: [],
        minted: 0n,
        fiatPaid: 0n,
        fiatReceived: 0n,
        identityCost: 0n,
        deals: 0,
        idle: 0,
        outcomes: {},
      };
      a.ids.push(await newIdentity(scn, a));
      agents.push(a);
    }
  }
  const outcomes: Record<string, number> = {};
  const cheatOutcomes: Record<string, number> = {};
  let unmatchedHonest = 0;

  for (let round = 0; round < ROUNDS; round++) {
    // Match: every Holder looks for a Provider both sides accept, in a random order.
    const holders = shuffle(agents.filter((a) => a.role === "holder"));
    const free = new Set(agents.filter((a) => a.role === "provider"));
    const pairs: [Agent, Agent][] = [];
    for (const h of holders) {
      let matched = false;
      for (const p of shuffle([...free])) {
        if ((await acceptable(scn, cur(h))) && (await acceptable(scn, cur(p)))) {
          pairs.push([h, p]);
          free.delete(p);
          matched = true;
          break;
        }
      }
      if (!matched) h.idle++;
    }
    for (const p of free) p.idle++;

    // Excluded cheaters buy a fresh identity; excluded honest agents are counted, not rescued.
    for (const a of agents) {
      const shunned = !(await acceptable(scn, cur(a)));
      if (shunned && a.strategy !== "honest") {
        a.ids.push(await newIdentity(scn, a));
        a.identityCost += IDENTITY_COST;
      } else if (shunned) {
        unmatchedHonest++;
      }
    }

    // Phase 1: activate, and the Provider does what its strategy does.
    const deals: Deal[] = [];
    for (const [h, p] of pairs) {
      const principal = [await capOf(scn, cur(h)), await capOf(scn, cur(p))].reduce((x, y) => (x < y ? x : y));
      const d = await activate(scn, h, p, principal);
      if (p.strategy !== "liar") {
        p.fiatPaid += principal;
        h.fiatReceived += principal;
        d.paid = true;
      }
      await send(cur(p).account, escrow, ESCROW, "markFiat", [d.id]);
      deals.push(d);
    }

    // Phase 2: the Holder answers. Paid and honest: release (or forget). Not paid: dispute or go to court.
    // Paid and an extortionist: dispute to claw back half.
    for (const d of deals) {
      const H = cur(d.holder);
      const wronged = !d.paid;
      const extorting = d.paid && d.holder.strategy === "extortionist";
      if (!wronged && !extorting) {
        if (rand() < FORGET_RATE) d.forgot = true;
        else await send(H.account, escrow, ESCROW, "release", [d.id]);
        continue;
      }
      if (wronged && scn.tribunal) {
        await send(H.account, escrow, ESCROW, "openCourt", [d.id]);
        d.court = true;
        continue;
      }
      await send(H.account, escrow, ESCROW, "openDisputed", [d.id]);
      d.disputed = true;
      // Who gives way. The honest outcome is the cancel when the Holder was not paid, the release when
      // it was. A rational cheater concedes it; a stubborn one waits — and a victim that yields hands it
      // the opposite outcome instead of facing the burn. With a tribunal, the extortionist (who never
      // escalates) simply runs into the clock and loses the pot: nobody signs anything.
      if (scn.tribunal) continue;
      const cheaterYields = !scn.stubborn;
      const honest = wronged; // wronged => the honest outcome is the cancel (all back to the Holder)
      if (cheaterYields) await allOrNothing(d, honest);
      else if (scn.victimYields) await allOrNothing(d, !honest);
    }

    // Phase 3: a truthful tribunal rules the cases in front of it.
    for (const d of deals.filter((x) => x.court)) {
      await test.impersonateAccount({ address: "0x000000000000000000000000000000000000071b" });
      await test.setBalance({ address: "0x000000000000000000000000000000000000071b", value: 10n ** 18n });
      await send("0x000000000000000000000000000000000000071b", dep.arbitration, COURT, "submitRuling", [d.id, d.paid ? 2 : 1]);
      await test.stopImpersonatingAccount({ address: "0x000000000000000000000000000000000000071b" });
      await send(admin, escrow, ESCROW, "readRuling", [d.id]);
    }

    // Phase 4: the clocks. Forgotten releases are claimed; disputes nobody settled time out.
    await warp(DISPUTE_DURATION + 1n);
    for (const d of deals) {
      const st = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
      if (st === "FIAT_SENT") await send(cur(d.provider).account, escrow, ESCROW, "claim", [d.id]);
      if (st === "DISPUTED") await send(admin, escrow, ESCROW, "forceDisputeTimeout", [d.id]);
      const end = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
      outcomes[end] = (outcomes[end] ?? 0) + 1;
      d.holder.outcomes[end] = (d.holder.outcomes[end] ?? 0) + 1;
      d.provider.outcomes[end] = (d.provider.outcomes[end] ?? 0) + 1;
      const cheat = !d.paid ? "liar" : d.holder.strategy === "extortionist" ? "extortion" : null;
      if (cheat) {
        const k = `${cheat}→${end}`;
        cheatOutcomes[k] = (cheatOutcomes[k] ?? 0) + 1;
      }
    }

    // Bonds burned in a deadlock are topped back up, and the top-up is counted as minted.
    if (scn.packaged) {
      for (const a of agents) {
        const id = cur(a);
        const deposited = (await read(dep.bondVault, VAULT, "deposited", [id.subject, token])) as bigint;
        if (deposited < BOND_DEPOSIT) {
          await mint(a, id.account.address, BOND_DEPOSIT - deposited);
          await send(id.account, dep.bondVault, VAULT, "deposit", [id.subject, token, BOND_DEPOSIT - deposited]);
        }
      }
    }
  }

  const w = new Map<Agent, bigint>();
  const pen = new Map<Agent, number>();
  for (const a of agents) {
    w.set(a, await worth(scn, a));
    pen.set(a, await penaltyOf(scn, cur(a)));
  }
  return { scenario: scn, agents, worth: w, penalty: pen, outcomes, cheatOutcomes, unmatchedHonest };
}

// ---------------------------------------------------------------- report

function group(r: Result, role: Role, strategy: Strategy) {
  const xs = r.agents.filter((a) => a.role === role && a.strategy === strategy);
  const total = xs.reduce((s, a) => s + (r.worth.get(a) ?? 0n), 0n);
  const deals = xs.reduce((s, a) => s + a.deals, 0);
  const ids = xs.reduce((s, a) => s + a.ids.length, 0);
  const pen = xs.reduce((s, a) => s + (r.penalty.get(a) ?? 0), 0) / Math.max(xs.length, 1);
  return { n: xs.length, perAgent: total / BigInt(Math.max(xs.length, 1)), deals, ids, pen, perDeal: deals ? total / BigInt(deals) : 0n };
}

async function main() {
  console.log(`\nPluriSwap — simulación de ecosistema · ${ROUNDS} rondas · seed ${SEED}`);
  console.log(`reglas: sin split tras disputa · deadlock sin tribunal quema el principal`);
  console.log(`población: 6 Holders honestos, 2 extorsionadores · 6 Providers honestos, 2 mentirosos\n`);
  const results: Result[] = [];
  for (const scn of SCENARIOS) {
    process.stdout.write(`  corriendo ${scn.key} · ${scn.name} ... `);
    const t0 = Date.now();
    results.push(await runScenario(scn));
    console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s`);
  }

  const rows: [Role, Strategy, string][] = [
    ["holder", "honest", "Holder honesto"],
    ["holder", "extortionist", "Holder extorsionador"],
    ["provider", "honest", "Provider honesto"],
    ["provider", "liar", "Provider mentiroso"],
  ];
  console.log("\nResultado neto por agente (tokens, fiat incluido), y penalty final de su identidad vigente\n");
  const header = ["", ...results.map((r) => r.scenario.key)];
  console.log(header.map((h, i) => (i === 0 ? h.padEnd(24) : h.padStart(24))).join(""));
  for (const [role, strat, label] of rows) {
    const cells = results.map((r) => {
      const g = group(r, role, strat);
      return `${fmt(g.perAgent)} (pen ${g.pen.toFixed(0)}, id ${g.ids / g.n})`.padStart(24);
    });
    console.log(label.padEnd(24) + cells.join(""));
  }
  console.log("\nEscenarios:");
  for (const r of results) console.log(`  ${r.scenario.key}  ${r.scenario.name}`);

  console.log("\nCómo terminó cada trampa");
  for (const r of results) {
    const parts = Object.entries(r.cheatOutcomes).map(([k, v]) => `${k} ×${v}`).join(", ");
    console.log(`  ${r.scenario.key}  ${parts || "—"}   · honestos excluidos: ${r.unmatchedHonest}`);
  }

  console.log("\nTerminales por escenario");
  for (const r of results) {
    console.log(`  ${r.scenario.key}  ${Object.entries(r.outcomes).map(([k, v]) => `${k} ${v}`).join(" · ")}`);
  }

  console.log("\nGas promedio por verbo (lo que paga quien lo llama)");
  for (const [verb, g] of [...gasByVerb.entries()].sort()) {
    if (["approve", "mint", "setHuman", "deposit", "submitRuling"].includes(verb)) continue;
    console.log(`  ${verb.padEnd(22)} ${(Number(g.gas) / g.n / 1000).toFixed(0).padStart(6)}k   (${g.n} llamadas)`);
  }

  const json = results.map((r) => ({
    scenario: r.scenario,
    outcomes: r.outcomes,
    cheatOutcomes: r.cheatOutcomes,
    unmatchedHonest: r.unmatchedHonest,
    groups: Object.fromEntries(
      rows.map(([role, strat, label]) => {
        const g = group(r, role, strat);
        return [label, { perAgent: fmt(g.perAgent), perDeal: fmt(g.perDeal), deals: g.deals, identities: g.ids, penalty: g.pen }];
      }),
    ),
  }));
  writeFileSync(OUT, JSON.stringify({ rounds: ROUNDS, seed: SEED, results: json, gas: Object.fromEntries([...gasByVerb].map(([k, v]) => [k, { calls: v.n, avg: Number(v.gas) / v.n }])) }, null, 2));
  console.log(`\nwrote ${OUT}`);
}

// Run only when executed directly: `longrun.ts` imports the machinery above.
if (import.meta.main) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
