// An imperfect tribunal in the long run: at what accuracy does honesty stop being the stable outcome?
//
// Schwartzbach (2020, arXiv:2008.10326) proves that escrow with an arbiter is incentive-compatible — honesty
// the unique subgame-perfect equilibrium AND an evolutionarily stable strategy — whenever the arbiter errs
// with probability gamma < 1/2 and the wager lambda sits in  x*gamma/(1-gamma) < lambda < x*(1-gamma)/gamma.
// Most of that design is ALREADY this kernel: the wager is the bond (on a verdict the loser's lock goes to
// the winner — his "winner rebate"), and not escalating a dispute you opened forfeits it (`ABANDONED`).
// With the official 10% bond, the bound says the tribunal must be right roughly 90% of the time.
//
// This measures it on the real contracts: the same evolutionary dynamics as `longrun.ts` (imitation +
// mutation, a 2% surplus per completed exchange, fresh identities for the shunned), in four markets whose
// tribunal is right 100%, 90%, 80% and 70% of the time, each with a realistic court fee.
//
// With an imperfect tribunal cheating becomes a bet on its errors:
//   liar           marks fiat without paying; the honest Holder takes it to court
//   extortionist   is paid, then opens the court itself claiming it was not
//   cheat-rational bets only when the bet is worth more than honest trading, knowing the accuracy
//                  (a liar who would not bet signs the cancel; an extortionist who would not bet releases)
//   cheat-stubborn always bets
//
// It also keeps the honest victim's ledger per case — the court fee advanced, and what came back — because
// the question behind the redesign is whether somebody without capital can still afford to be right.
//
// Run: script/sim/run.sh 8546 --tribunal        (GENERATIONS, ROUNDS_PER_GEN, PER_ROLE, SEED, COURT_FEE)

import { writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { keccak256, toHex, type Address, type Hex } from "viem";
import {
  activate,
  acceptable,
  admin,
  allOrNothing,
  BOND_DEPOSIT,
  capOf,
  COURT,
  cur,
  dep,
  escrow,
  ESCROW,
  fmt,
  IDENTITY_COST,
  mint,
  newIdentity,
  pub,
  rand,
  read,
  send,
  shuffle,
  STATUS,
  T,
  test,
  token,
  VAULT,
  wallet,
  warp,
  worth,
  type Agent,
  type Deal,
  type Role,
  type Scenario,
} from "./ecosystem.ts";

const GENERATIONS = Number(process.env.GENERATIONS ?? 14);
const ROUNDS_PER_GEN = Number(process.env.ROUNDS_PER_GEN ?? 4);
const PER_ROLE = Number(process.env.PER_ROLE ?? 8);
const COURT_FEE = T(Number(process.env.COURT_FEE ?? 25)); // what opening the court costs, in the token
const COURT_CONTEST = T(0.5); // the court's own contest fee (as in DeployPackages)
const REP_CONTEST = T(2); // the official reputation package's contest floor
const SURPLUS_BPS = 200n;
const MUTATION = 0.03;
const FORGET = 0.1;
const OUT = process.env.SIM_OUT ?? "/tmp/pluriswap-tribunal.json";
const TRIBUNAL = "0x000000000000000000000000000000000000071b" as const;

type Trait = "honest-firm" | "honest-yield" | "cheat-rational" | "cheat-stubborn";
const TRAITS: Trait[] = ["honest-firm", "honest-yield", "cheat-rational", "cheat-stubborn"];
const cheats = (p: Player) => p.trait.startsWith("cheat");

interface Player extends Agent {
  trait: Trait;
  surplus: bigint;
  genStart: bigint;
  genPayoff: bigint;
}

interface Market extends Scenario {
  accuracy: number;
}

interface Ledger {
  cases: number;
  wrong: number;
  victimNet: bigint; // honest victims, summed: what came back less what was lost or advanced
  victimPositive: number; // cases in which the honest victim ended no worse than before
  feesAdvanced: bigint;
}

async function deployCourt(): Promise<{ court: Address; courtId: Hex }> {
  const art = JSON.parse(readFileSync(join(import.meta.dir, "../../out/ArbitrationMock.sol/ArbitrationMock.json"), "utf8"));
  // The mock calls two external libraries; link them to the instances forge deployed for this run.
  const libs: string[] = JSON.parse(
    readFileSync(join(import.meta.dir, "../../broadcast/DeployPackages.s.sol/31337/run-latest.json"), "utf8"),
  ).libraries;
  let bytecode = art.bytecode.object as string;
  for (const entry of libs) {
    const at = entry.lastIndexOf(":");
    const placeholder = `__$${keccak256(toHex(entry.slice(0, at))).slice(2, 36)}$__`;
    bytecode = bytecode.split(placeholder).join(entry.slice(at + 3).toLowerCase());
  }
  if (bytecode.includes("__$")) throw new Error("ArbitrationMock: an unlinked library remains");
  const hash = await wallet.deployContract({
    abi: art.abi,
    bytecode: bytecode as Hex,
    account: admin,
    args: [TRIBUNAL, token, COURT_FEE, 7n * 86_400n, escrow, COURT_CONTEST, dep.feeRecipient],
  } as never);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  const court = receipt.contractAddress as Address;
  const courtId = (await read(court, COURT, "packageId")) as Hex;
  return { court, courtId };
}

const bondOf = (principal: bigint) => (principal + 9n) / 10n; // §E.3.14.5, the same curve as the vault

/// Does a rational cheater bet on the tribunal's error? Only if the bet is worth more than trading honestly.
function worthBetting(m: Market, principal: bigint, extortion: boolean): boolean {
  const g = 1 - m.accuracy;
  const P = Number(principal);
  const b = Number(bondOf(principal));
  const fees = extortion ? Number(COURT_FEE + COURT_CONTEST + REP_CONTEST) : 0; // the liar pays nothing to be sued
  const honest = extortion ? (P * Number(SURPLUS_BPS)) / 10_000 : 0; // a liar who concedes gets 0 either way
  const bet = g * (P + b) - (1 - g) * b - fees;
  return bet > honest;
}

async function runMarket(m: Market) {
  const players: Player[] = [];
  for (const role of ["holder", "provider"] as Role[]) {
    for (let i = 0; i < PER_ROLE; i++) {
      const p: Player = {
        name: `${role}-${i}`,
        role,
        strategy: "honest",
        trait: TRAITS[i % TRAITS.length],
        ids: [],
        minted: 0n,
        fiatPaid: 0n,
        fiatReceived: 0n,
        identityCost: 0n,
        deals: 0,
        idle: 0,
        outcomes: {},
        surplus: 0n,
        genStart: 0n,
        genPayoff: 0n,
      };
      p.ids.push(await newIdentity(m, p));
      players.push(p);
    }
  }
  const ledger: Ledger = { cases: 0, wrong: 0, victimNet: 0n, victimPositive: 0, feesAdvanced: 0n };
  const history: { gen: number; honest: number; cheatAvg: string; honestAvg: string }[] = [];

  for (let gen = 0; gen < GENERATIONS; gen++) {
    for (const p of players) p.genStart = (await worth(m, p)) + p.surplus;
    for (let r = 0; r < ROUNDS_PER_GEN; r++) await playRound(m, players, ledger);
    for (const p of players) p.genPayoff = (await worth(m, p)) + p.surplus - p.genStart;

    const honestN = players.filter((p) => !cheats(p)).length;
    const avg = (xs: Player[]) => (xs.length ? fmt(xs.reduce((s, p) => s + p.genPayoff, 0n) / BigInt(xs.length)) : "—");
    history.push({ gen, honest: honestN, honestAvg: avg(players.filter((p) => !cheats(p))), cheatAvg: avg(players.filter(cheats)) });
    const bar = "█".repeat(honestN) + "░".repeat(players.length - honestN);
    console.log(`    gen ${String(gen).padStart(2)}  ${bar}  honestos ${honestN}/${players.length}   (honesto ${history[gen].honestAvg} · tramposo ${history[gen].cheatAvg})`);

    for (const role of ["holder", "provider"] as Role[]) {
      const group = players.filter((x) => x.role === role);
      let maxDiff = 1n;
      for (const a of group) for (const b of group) if (b.genPayoff - a.genPayoff > maxDiff) maxDiff = b.genPayoff - a.genPayoff;
      const next = group.map((a) => {
        if (rand() < MUTATION) return TRAITS[Math.floor(rand() * TRAITS.length)];
        const b = group[Math.floor(rand() * group.length)];
        const d = b.genPayoff - a.genPayoff;
        return d > 0n && rand() < Number(d) / Number(maxDiff) ? b.trait : a.trait;
      });
      group.forEach((a, i) => (a.trait = next[i]));
    }
  }
  return { market: m, history, ledger, players };
}

async function playRound(m: Market, players: Player[], ledger: Ledger) {
  for (const p of players) {
    if (!(await acceptable(m, cur(p)))) {
      p.ids.push(await newIdentity(m, p));
      p.identityCost += IDENTITY_COST;
    }
  }
  const holders = shuffle(players.filter((a) => a.role === "holder"));
  const free = new Set(players.filter((a) => a.role === "provider"));
  const deals: (Deal & { h: Player; p: Player; victim?: Player })[] = [];
  for (const h of holders) {
    const p = shuffle([...free])[0];
    if (!p) break;
    free.delete(p);
    const principal = [await capOf(m, cur(h)), await capOf(m, cur(p))].reduce((x, y) => (x < y ? x : y));
    const d = await activate(m, h, p, principal);
    if (!cheats(p)) {
      p.fiatPaid += principal;
      h.fiatReceived += principal;
      d.paid = true;
    }
    await send(cur(p).account, escrow, ESCROW, "markFiat", [d.id]);
    deals.push({ ...d, h, p });
  }

  for (const d of deals) {
    const H = cur(d.h);
    if (d.paid && !cheats(d.h)) {
      if (rand() >= FORGET) await send(H.account, escrow, ESCROW, "release", [d.id]);
      continue;
    }
    if (d.paid) {
      // An extortionist: bets on the court's error, or — if rational and the bet is bad — releases.
      if (d.h.trait === "cheat-rational" && !worthBetting(m, d.principal, true)) {
        await send(H.account, escrow, ESCROW, "release", [d.id]);
        continue;
      }
      await send(H.account, escrow, ESCROW, "openCourt", [d.id]);
      d.court = true;
      if (!cheats(d.p)) d.victim = d.p;
      continue;
    }
    // Not paid: the Holder sues. A rational liar who would lose the bet signs the cancel first.
    await send(H.account, escrow, ESCROW, "openCourt", [d.id]);
    d.court = true;
    if (!cheats(d.h)) d.victim = d.h;
    if (d.p.trait === "cheat-rational" && !worthBetting(m, d.principal, false)) {
      await allOrNothing(d, true);
      d.court = false;
      if (d.victim) {
        ledger.cases++;
        ledger.feesAdvanced += COURT_FEE;
        const net = -(COURT_FEE + COURT_CONTEST + REP_CONTEST); // made whole, less what suing cost
        ledger.victimNet += net;
      }
    }
  }

  // The tribunal rules: right with probability `accuracy`.
  for (const d of deals.filter((x) => x.court)) {
    const right = rand() < m.accuracy;
    const truth = d.paid ? 2 : 1; // ProviderWin if fiat moved, HolderWin if it did not
    const ruling = right ? truth : 3 - truth;
    await test.impersonateAccount({ address: TRIBUNAL });
    await test.setBalance({ address: TRIBUNAL, value: 10n ** 18n });
    await send(TRIBUNAL, m.court!, COURT, "submitRuling", [d.id, ruling]);
    await test.stopImpersonatingAccount({ address: TRIBUNAL });
    await send(admin, escrow, ESCROW, "readRuling", [d.id]);
    if (d.victim) {
      ledger.cases++;
      if (!right) ledger.wrong++;
      const b = bondOf(d.principal);
      // The victim advanced the fees only if it opened the court (the Holder side); an extortion victim did not.
      const advanced = d.victim === d.h ? COURT_FEE + COURT_CONTEST + REP_CONTEST : 0n;
      if (d.victim === d.h) ledger.feesAdvanced += COURT_FEE;
      const net = right ? b - advanced : -(d.principal + b + advanced);
      ledger.victimNet += net;
      if (net >= 0n) ledger.victimPositive++;
    }
  }

  await warp(86_400n * 8n);
  for (const d of deals) {
    let st = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
    if (st === "FIAT_SENT") await send(cur(d.p).account, escrow, ESCROW, "claim", [d.id]);
    st = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
    if (d.paid && (st === "RELEASED" || st === "CLAIMED")) {
      const s = (d.principal * SURPLUS_BPS) / 10_000n;
      d.h.surplus += s;
      d.p.surplus += s;
    }
  }

  for (const p of players) {
    const id = cur(p);
    const deposited = (await read(dep.bondVault, VAULT, "deposited", [id.subject, token])) as bigint;
    if (deposited < BOND_DEPOSIT) {
      await mint(p, id.account.address, BOND_DEPOSIT - deposited);
      await send(id.account, dep.bondVault, VAULT, "deposit", [id.subject, token, BOND_DEPOSIT - deposited]);
    }
  }
}

async function main() {
  console.log(`\nPluriSwap — tribunal imperfecto en el largo plazo`);
  console.log(`${GENERATIONS} generaciones × ${ROUNDS_PER_GEN} rondas · ${PER_ROLE} por rol · bond 10% · court fee ${fmt(COURT_FEE)}`);
  console.log(`cota de Schwartzbach con bond 10%: el tribunal tiene que acertar más de ~${(100 / 1.1).toFixed(0)}%\n`);
  const out = [];
  for (const accuracy of [1.0, 0.9, 0.8, 0.7]) {
    const { court, courtId } = await deployCourt();
    const m: Market = {
      key: `T${Math.round(accuracy * 100)}`,
      name: `Tribunal que acierta ${Math.round(accuracy * 100)}%`,
      packaged: true,
      tribunal: true,
      stubborn: true,
      victimYields: false,
      court,
      courtId,
      accuracy,
    };
    console.log(`  ${m.key} · ${m.name}`);
    const r = await runMarket(m);
    const L = r.ledger;
    const last = r.history.slice(-4);
    const honestEnd = r.history[r.history.length - 1].honest;
    console.log(
      `    → honestos al final ${honestEnd}/${PER_ROLE * 2} · casos con víctima honesta ${L.cases} (tribunal erró ${L.wrong})` +
        ` · resultado medio de la víctima por caso ${L.cases ? fmt(L.victimNet / BigInt(L.cases)) : "—"}` +
        ` · víctimas que no perdieron ${L.cases ? Math.round((100 * L.victimPositive) / L.cases) : 0}%\n`,
    );
    out.push({ market: m.name, accuracy, history: r.history, ledger: { ...L, victimNet: fmt(L.victimNet), feesAdvanced: fmt(L.feesAdvanced) }, last });
  }
  writeFileSync(OUT, JSON.stringify({ generations: GENERATIONS, roundsPerGen: ROUNDS_PER_GEN, perRole: PER_ROLE, courtFee: fmt(COURT_FEE), markets: out }, null, 2));
  console.log(`wrote ${OUT}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
