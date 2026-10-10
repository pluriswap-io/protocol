// The long run: does the population converge to honesty?
//
// `ecosystem.ts` plays a few rounds with strategies fixed, which answers "can a cheater win a game?".
// The question that decides whether a market survives is a different one: when people can change what
// they do according to how it went, WHERE DOES THE POPULATION GO? A rule set is sound in the long run if
// cheating does worse on average than honesty, so that imitation drains it — even if, on the way, a
// cheater wins a game or two.
//
// The model is evolutionary (imitation dynamics — the practical form of the replicator dynamics):
//
//   * every agent carries a TRAIT: honest-firm, honest-yield, cheat-rational, cheat-stubborn
//       honest-firm     pays and releases; as a victim, never hands a cheater anything (would rather burn)
//       honest-yield    pays and releases; as a victim of a stubborn cheater, hands it the pot to avoid
//                       the burn (it saves its bond and its score)
//       cheat-rational  cheats (a Holder disputes after being paid; a Provider marks fiat without paying),
//                       and gives way the moment it is disputed or it would lose
//       cheat-stubborn  cheats and never gives way
//   * every generation is a few rounds of real trading on chain; then each agent looks at another agent
//     of its own role and, if that one earned more, copies its trait with a probability proportional to
//     the difference; a small mutation rate stands for newcomers and experiments;
//   * a completed exchange is worth something to both sides — a SURPLUS of 2% of the principal each —
//     because that is why people trade at all; without it "not trading" ties "trading honestly";
//   * anyone shunned by the market (penalty band >= 2) may buy a fresh identity, honest or not.
//
// It runs the same starting population (a quarter of each trait, per role) through three markets on the
// current kernel — after a dispute only all-or-nothing agreements, and a deadlock without a tribunal
// burns the principal — and reports the trait shares per generation and where they end.
//
// Run: script/sim/run.sh 8546 --longrun        (GENERATIONS, ROUNDS_PER_GEN, SEED)

import {
  activate,
  acceptable,
  allOrNothing,
  capOf,
  cur,
  dep,
  escrow,
  ESCROW,
  COURT,
  fmt,
  IDENTITY_COST,
  mint,
  newIdentity,
  penaltyOf,
  rand,
  read,
  send,
  shuffle,
  STATUS,
  test,
  admin,
  token,
  VAULT,
  BOND_DEPOSIT,
  worth,
  warp,
  DISPUTE_DURATION,
  type Agent,
  type Deal,
  type Role,
  type Scenario,
} from "./ecosystem.ts";
import { writeFileSync } from "node:fs";

const GENERATIONS = Number(process.env.GENERATIONS ?? 12);
const ROUNDS_PER_GEN = Number(process.env.ROUNDS_PER_GEN ?? 4);
const PER_ROLE = Number(process.env.PER_ROLE ?? 8);
const SURPLUS_BPS = 200n; // what a completed exchange is worth to EACH side
const MUTATION = 0.03;
const FORGET = 0.1;
const OUT = process.env.SIM_OUT ?? "/tmp/pluriswap-longrun.json";

type Trait = "honest-firm" | "honest-yield" | "cheat-rational" | "cheat-stubborn";
const TRAITS: Trait[] = ["honest-firm", "honest-yield", "cheat-rational", "cheat-stubborn"];

interface Player extends Agent {
  trait: Trait;
  surplus: bigint;
  genStart: bigint;
  genPayoff: bigint;
}

const cheats = (p: Player) => p.trait.startsWith("cheat");
const TRIBUNAL = "0x000000000000000000000000000000000000071b" as const;

interface Market extends Scenario {}

const MARKETS: Market[] = [
  { key: "L1", name: "Core puro", packaged: false, tribunal: false, stubborn: false, victimYields: false },
  { key: "L2", name: "Oficial sin tribunal", packaged: true, tribunal: false, stubborn: false, victimYields: false },
  { key: "L3", name: "Oficial con tribunal", packaged: true, tribunal: true, stubborn: false, victimYields: false },
];

async function score(m: Market, p: Player) {
  return (await worth(m, p)) + p.surplus;
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
  const history: { gen: number; shares: Record<string, Record<Trait, number>>; avg: Record<string, string> }[] = [];

  for (let gen = 0; gen < GENERATIONS; gen++) {
    for (const p of players) p.genStart = await score(m, p);
    for (let round = 0; round < ROUNDS_PER_GEN; round++) await playRound(m, players);
    for (const p of players) p.genPayoff = (await score(m, p)) - p.genStart;

    // Record, then imitate.
    const shares: Record<string, Record<Trait, number>> = {};
    const sums: Record<string, { s: bigint; n: number }> = {};
    for (const role of ["holder", "provider"]) {
      shares[role] = Object.fromEntries(TRAITS.map((t) => [t, 0])) as Record<Trait, number>;
      for (const p of players.filter((x) => x.role === role)) {
        shares[role][p.trait]++;
        const k = `${role}:${p.trait}`;
        sums[k] = sums[k] ?? { s: 0n, n: 0 };
        sums[k].s += p.genPayoff;
        sums[k].n++;
      }
    }
    const avg = Object.fromEntries(Object.entries(sums).map(([k, v]) => [k, fmt(v.s / BigInt(v.n))]));
    history.push({ gen, shares, avg });
    const line = (role: string) => TRAITS.map((t) => `${t.replace("honest-", "H·").replace("cheat-", "C·")} ${shares[role][t]}`).join("  ");
    console.log(`    gen ${String(gen).padStart(2)}  holders[ ${line("holder")} ]  providers[ ${line("provider")} ]`);

    for (const role of ["holder", "provider"] as Role[]) {
      const group = players.filter((x) => x.role === role);
      const maxDiff = group.reduce((mx, a) => {
        for (const b of group) {
          const d = b.genPayoff - a.genPayoff;
          if (d > mx) mx = d;
        }
        return mx;
      }, 1n);
      const next = group.map((a) => {
        if (rand() < MUTATION) return TRAITS[Math.floor(rand() * TRAITS.length)];
        const b = group[Math.floor(rand() * group.length)];
        const d = b.genPayoff - a.genPayoff;
        if (d > 0n && rand() < Number(d) / Number(maxDiff)) return b.trait;
        return a.trait;
      });
      group.forEach((a, i) => (a.trait = next[i]));
    }
  }
  return { market: m, history, players };
}

async function playRound(m: Market, players: Player[]) {
  // Anyone the market shuns buys a fresh identity (a cheater to keep cheating, an honest agent to keep
  // trading); the cost is counted against them.
  for (const p of players) {
    if (!(await acceptable(m, cur(p)))) {
      p.ids.push(await newIdentity(m, p));
      p.identityCost += IDENTITY_COST;
    }
  }
  const holders = shuffle(players.filter((a) => a.role === "holder"));
  const free = new Set(players.filter((a) => a.role === "provider"));
  const deals: (Deal & { h: Player; p: Player })[] = [];
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
    const wronged = !d.paid;
    const extorting = d.paid && cheats(d.h);
    if (!wronged && !extorting) {
      if (rand() >= FORGET) await send(H.account, escrow, ESCROW, "release", [d.id]);
      continue;
    }
    if (wronged && m.tribunal) {
      await send(H.account, escrow, ESCROW, "openCourt", [d.id]);
      d.court = true;
      continue;
    }
    await send(H.account, escrow, ESCROW, "openDisputed", [d.id]);
    const cheater = wronged ? d.p : d.h;
    const victim = wronged ? d.h : d.p;
    if (m.tribunal) {
      // Only the extortionist reaches here: it never escalates. A rational one releases (0) rather than
      // run into the clock (0 and +5); a stubborn one runs into it and forfeits the pot.
      if (cheater.trait === "cheat-rational") await allOrNothing(d, false);
      continue;
    }
    // Without a tribunal: the cheater concedes if rational; otherwise a yielding victim hands it the
    // opposite outcome to avoid the burn; otherwise the clock burns it all.
    if (cheater.trait === "cheat-rational") await allOrNothing(d, wronged);
    else if (victim.trait === "honest-yield") await allOrNothing(d, !wronged);
  }

  for (const d of deals.filter((x) => x.court)) {
    await test.impersonateAccount({ address: TRIBUNAL });
    await test.setBalance({ address: TRIBUNAL, value: 10n ** 18n });
    await send(TRIBUNAL, dep.arbitration, COURT, "submitRuling", [d.id, d.paid ? 2 : 1]);
    await test.stopImpersonatingAccount({ address: TRIBUNAL });
    await send(admin, escrow, ESCROW, "readRuling", [d.id]);
  }

  await warp(DISPUTE_DURATION + 1n);
  for (const d of deals) {
    let st = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
    if (st === "FIAT_SENT") await send(cur(d.p).account, escrow, ESCROW, "claim", [d.id]);
    if (st === "DISPUTED") await send(admin, escrow, ESCROW, "forceDisputeTimeout", [d.id]);
    st = STATUS[Number(await read(escrow, ESCROW, "status", [d.id]))];
    // The exchange really happened: fiat moved and the crypto reached the Provider.
    if (d.paid && (st === "RELEASED" || st === "CLAIMED")) {
      const s = (d.principal * SURPLUS_BPS) / 10_000n;
      d.h.surplus += s;
      d.p.surplus += s;
    }
  }

  if (m.packaged) {
    for (const p of players) {
      const id = cur(p);
      const deposited = (await read(dep.bondVault, VAULT, "deposited", [id.subject, token])) as bigint;
      if (deposited < BOND_DEPOSIT) {
        await mint(p, id.account.address, BOND_DEPOSIT - deposited);
        await send(id.account, dep.bondVault, VAULT, "deposit", [id.subject, token, BOND_DEPOSIT - deposited]);
      }
    }
  }
}

async function main() {
  console.log(`\nPluriSwap — largo plazo · ${GENERATIONS} generaciones × ${ROUNDS_PER_GEN} rondas · ${PER_ROLE} por rol`);
  console.log(`H·firm honesto firme · H·yield honesto que cede · C·rational tramposo racional · C·stubborn tramposo terco\n`);
  const out = [];
  for (const m of MARKETS) {
    console.log(`  ${m.key} · ${m.name}`);
    const r = await runMarket(m);
    out.push({ market: m.name, history: r.history });
    const last = r.history[r.history.length - 1];
    const honest = (role: string) => last.shares[role]["honest-firm"] + last.shares[role]["honest-yield"];
    console.log(
      `    → honestos al final: ${honest("holder")}/${PER_ROLE} holders, ${honest("provider")}/${PER_ROLE} providers\n`,
    );
  }
  writeFileSync(OUT, JSON.stringify({ generations: GENERATIONS, roundsPerGen: ROUNDS_PER_GEN, perRole: PER_ROLE, markets: out }, null, 2));
  console.log(`wrote ${OUT}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
