// What an official deal costs each side, as a share of the principal — and how much of a P2P spread it eats.
//
// Pure arithmetic, no chain: every number is a parameter below, and each one says where it came from. The gas
// is measured where the suite measures it and marked `est` where it is composed from measured parts. The
// package shares and the panel's availability fee are the decided ones (Anexo R, 2026-09-28); the panel is paid
// for deciding out of the loser's bond, 30% of the lock (Anexo R, 2026-10-05) — there is no dispute fee.
//
// Every official deal is a private-layer deal (PASSPORT + REPUTATION on the private stack), with a minimum
// of 250 tokens. Core (no packages) is listed for reference only.
//
// Run: bun script/sim/fees.ts
//      FEES='{"ethUsd":3000,"panel":{"availabilityBps":10}}' bun script/sim/fees.ts   (deep-merged overrides)

type Gas = { l2: number; l1Bytes: number };
type Line = { who: "holder" | "provider"; what: string; usd: number };

const DEFAULTS = {
  principals: [250, 1_000, 5_000],
  spreadsBps: [50, 100, 200], // P2P spread scenarios to compare against — NOT surveyed yet
  ethUsd: 2_650, // 2026-09-28
  market: {
    quiet: { l2Gwei: 0.02, blobGwei: 0.01 }, // Arbitrum One on 2026-09-28: 0.02 gwei; blob at the EIP-7918 floor
    loaded: { l2Gwei: 0.1, blobGwei: 0.5 }, // blob at the top of its post-Fusaka range (0.01–0.5 gwei); L2 5x today
  },
  // Package fees (Anexo R, 2026-09-28; DeployPackages.s.sol / DeployPrivate.s.sol). Flat parts are in tokens.
  pkg: {
    activation: 0, // flat, Holder, on top of the principal
    activationBps: 30, // 0.3% of the principal, Holder, on top of it
    completion: 0, // flat, out of the pot, when the Provider is paid
    completionBps: 30, // 0.3% of the pot
    contestBps: 100, // opener, when disputing
    contestFloor: 2,
    zkVerify: 0.01, // PAYMENT_PROOF, when the proof releases
  },
  // The 3-arbiter panel (2026-09-28): 0.2% per arbiter for being available; for deciding, 30% of the loser's bond
  // lock (2026-10-05), split among the arbiters who voted with the ruling. No dispute fee.
  panel: {
    arbiters: 3,
    availabilityBps: 20, // per arbiter, pulled from the Holder at activation
    availabilityFloor: 0, // per arbiter
    bondShareBps: 3_000, // of the loser's lock (the lock is `bond.ratio` of the principal)
  },
  // Stargate V2, only when a side bridges in or out: ~6 bps plus the destination gas (taxi).
  // A 10,000 USDC Arbitrum→Base transfer quoted ~6 USDC fee + 1–2 USDC gas (May 2026).
  stargate: { bps: 6, taxiGasUsd: 1.5, busGasUsd: 0.3 }, // bus: est, the taxi gas shared by 2–10 passengers
  peer: { takerBps: 95, bridgeBps: 50 }, // peer.xyz, "up to", 2026-09-28
  bond: {
    ratio: 0.1, // ceil(P/10), the official lock
    apy: 0.05, // what the locked capital would earn elsewhere
    days: 2, // how long a deal keeps it locked
  },
  // Gas per step. Sources: EVALUACION.md LHF-5 (measured), HappyPath gas report (measured), `est` = composed.
  gas: {
    coreActivate: { l2: 434_823, l1Bytes: 1_500 },
    privateActivate: { l2: 3_557_484, l1Bytes: 19_200 }, // two-sided, PASSPORT+REP, two real verifies
    bondPrepare: { l2: 500_000, l1Bytes: 0 }, // est: note insert 438k + storage, per side; the proof is prepare_side's
    markFiat: { l2: 55_747, l1Bytes: 300 },
    release: { l2: 66_231, l1Bytes: 300 }, // Core; the packaged terminal adds its notifications
    releaseNotify: { l2: 120_000, l1Bytes: 0 }, // est: post-terminal notifications of REP (+ BONDS)
    claim: { l2: 1_470_000, l1Bytes: 9_600 }, // est: verify 746k + account insert 673k + storage, per side
    reabsorb: { l2: 1_120_000, l1Bytes: 9_600 }, // est: verify 685k + note insert 438k, per side
    proofRelease: { l2: 850_000, l1Bytes: 9_600 }, // est: a DKIM circuit does not exist; an UltraHonk verify + kernel
    panelActivate: { l2: 150_000, l1Bytes: 400 }, // est: capacity locks of 3 arbiters + fee escrow
    panelSettle: { l2: 100_000, l1Bytes: 0 }, // est: paying or refunding the availability fees
    dispute: { l2: 120_000, l1Bytes: 300 }, // est: openDisputed + openCourt
  } satisfies Record<string, Gas>,
};

type Params = typeof DEFAULTS;
type Market = keyof Params["market"];

function merge<T>(base: T, over: unknown): T {
  if (over === null || typeof over !== "object" || Array.isArray(over)) return (over ?? base) as T;
  const out: any = Array.isArray(base) ? [...(base as any)] : { ...(base as any) };
  for (const [k, v] of Object.entries(over as object)) out[k] = merge((base as any)?.[k], v);
  return out;
}

const P: Params = merge(DEFAULTS, process.env.FEES ? JSON.parse(process.env.FEES) : undefined);

const pct = (bps: number, floor: number, principal: number) => Math.max((principal * bps) / 10_000, floor);

function gasUsd(g: Gas, m: Market): number {
  const { l2Gwei, blobGwei } = P.market[m];
  return ((g.l2 * l2Gwei + g.l1Bytes * blobGwei) * 1e-9) * P.ethUsd;
}

type Profile = { name: string; bonds: boolean; proof: boolean; panel: boolean; dispute: boolean; core?: boolean };

const PROFILES: Profile[] = [
  { name: "Core (referencia, sin paquetes)", bonds: false, proof: false, panel: false, dispute: false, core: true },
  { name: "Oficial: Passport + reputación", bonds: false, proof: false, panel: false, dispute: false },
  { name: "Oficial + bonds", bonds: true, proof: false, panel: false, dispute: false },
  { name: "Oficial + prueba de pago, sin bonds", bonds: false, proof: true, panel: false, dispute: false },
  { name: "Oficial + bonds + prueba de pago", bonds: true, proof: true, panel: false, dispute: false },
  { name: "Oficial + bonds + panel, sin disputa", bonds: true, proof: false, panel: true, dispute: false },
  { name: "Oficial + bonds + panel, CON disputa", bonds: true, proof: false, panel: true, dispute: true },
];

function lines(p: Profile, principal: number, m: Market): Line[] {
  const L: Line[] = [];
  const add = (who: Line["who"], what: string, usd: number) => usd > 0 && L.push({ who, what, usd });
  const gas = (who: Line["who"], what: string, g: Gas) => add(who, `gas: ${what}`, gasUsd(g, m));

  if (p.core) {
    gas("holder", "activate", P.gas.coreActivate);
    gas("provider", "markFiat", P.gas.markFiat);
    gas("holder", "release", P.gas.release);
    return L;
  }

  // Activation: the Holder submits activate, carrying both sides' proofs.
  add("holder", "fee de activación", P.pkg.activation + (principal * P.pkg.activationBps) / 10_000);
  gas("holder", "activación privada (dos lados)", P.gas.privateActivate);
  if (p.bonds) {
    gas("holder", "prepare del bond", P.gas.bondPrepare);
    gas("provider", "prepare del bond", P.gas.bondPrepare);
    const carry = principal * P.bond.ratio * P.bond.apy * (P.bond.days / 365);
    add("holder", "costo de capital del bond", carry);
    add("provider", "costo de capital del bond", carry);
  }
  if (p.panel) {
    const each = pct(P.panel.availabilityBps, P.panel.availabilityFloor, principal);
    add("holder", `disponibilidad del panel (${P.panel.arbiters} × ${each.toFixed(2)})`, each * P.panel.arbiters);
    gas("holder", "bloqueo del panel", P.gas.panelActivate);
  }

  // The middle of the deal.
  if (p.proof) {
    add("provider", "fee de la prueba de pago", P.pkg.zkVerify);
    gas("provider", "release por prueba", P.gas.proofRelease);
  } else {
    gas("provider", "markFiat", P.gas.markFiat);
    if (p.dispute) {
      add("holder", "contest de reputación", pct(P.pkg.contestBps, P.pkg.contestFloor, principal));
      // The modelled ruling goes against the Holder: the panel's share of its lock is the dispute's price. The other
      // 70% of the lock moves to the Provider — a transfer between the parties, not a cost of the deal.
      add("holder", "parte del panel en el bond del perdedor", (principal * P.bond.ratio * P.panel.bondShareBps) / 10_000);
      gas("holder", "abrir disputa y corte", P.gas.dispute);
    }
    gas("holder", "release", { l2: P.gas.release.l2 + P.gas.releaseNotify.l2, l1Bytes: P.gas.release.l1Bytes });
  }
  if (p.panel) gas("holder", "liquidar el panel", P.gas.panelSettle);

  // The Provider is paid in every profile modelled here, so the completion fee applies.
  add("provider", "fee de cierre", P.pkg.completion + (principal * P.pkg.completionBps) / 10_000);

  // After the terminal: each side claims its reputation; with bonds, each reabsorbs its lock.
  gas("holder", "claim de reputación", P.gas.claim);
  gas("provider", "claim de reputación", P.gas.claim);
  if (p.bonds) {
    gas("holder", "reabsorb del bond", P.gas.reabsorb);
    gas("provider", "reabsorb del bond", P.gas.reabsorb);
  }
  return L;
}

const usd = (x: number) => (x < 0.01 ? x.toFixed(4) : x.toFixed(2));
const share = (x: number, principal: number) => `${((x / principal) * 100).toFixed(3)}%`;

function summary(m: Market) {
  const { l2Gwei, blobGwei } = P.market[m];
  console.log(`\n## Mercado ${m === "quiet" ? "quieto" : "cargado"} (L2 ${l2Gwei} gwei, blob ${blobGwei} gwei, ETH ${P.ethUsd} USD)\n`);
  const head = ["Perfil", ...P.principals.flatMap((x) => [`${x} Holder`, `${x} Provider`, `${x} total`])];
  console.log(`| ${head.join(" | ")} |`);
  console.log(`| ${head.map((_, i) => (i === 0 ? "---" : "---:")).join(" | ")} |`);
  for (const p of PROFILES) {
    const cells = P.principals.flatMap((principal) => {
      const L = lines(p, principal, m);
      const h = L.filter((l) => l.who === "holder").reduce((a, l) => a + l.usd, 0);
      const v = L.filter((l) => l.who === "provider").reduce((a, l) => a + l.usd, 0);
      return [share(h, principal), share(v, principal), share(h + v, principal)];
    });
    console.log(`| ${p.name} | ${cells.join(" | ")} |`);
  }

  console.log(`\nQué fracción del spread se come el total (deal de ${P.principals[0]}, el mínimo):\n`);
  const sh = ["Perfil", ...P.spreadsBps.map((b) => `spread ${(b / 100).toFixed(1)}%`)];
  console.log(`| ${sh.join(" | ")} |`);
  console.log(`| ${sh.map((_, i) => (i === 0 ? "---" : "---:")).join(" | ")} |`);
  const principal = P.principals[0];
  for (const p of PROFILES) {
    const total = lines(p, principal, m).reduce((a, l) => a + l.usd, 0);
    const cells = P.spreadsBps.map((b) => `${((total / ((principal * b) / 10_000)) * 100).toFixed(0)}%`);
    console.log(`| ${p.name} | ${cells.join(" | ")} |`);
  }
}

// Pricing scenarios against peer.xyz: the protocol's own fees in bps per side, on the deal Peer offers
// (a payment proof, no dispute) and on a deal that needs the panel instead. Market: quiet.
function pricing() {
  const scenarios = [
    { name: "0,5% Holder + 0,5% Provider", h: 50, v: 50 },
    { name: "0,25% Holder + 0,5% Provider", h: 25, v: 50 },
    { name: "0% Holder + 0,6% Provider", h: 0, v: 60 },
  ];
  const deals = [
    { label: "prueba de pago", profile: PROFILES.find((p) => p.name === "Oficial + prueba de pago, sin bonds")! },
    { label: "panel, sin disputa", profile: PROFILES.find((p) => p.name === "Oficial + bonds + panel, sin disputa")! },
  ];
  for (const bridge of ["sin bridge", "con Stargate (taxi)"] as const) {
    console.log(`\n## Pricing contra peer.xyz, ${bridge} (mercado quieto)\n`);
    const head = ["Escenario", "Deal", ...P.principals.map((x) => `${x}`)];
    console.log(`| ${head.join(" | ")} |`);
    console.log(`| ${head.map((_, i) => (i < 2 ? "---" : "---:")).join(" | ")} |`);
    const peer = P.principals.map((x) => {
      const bps = P.peer.takerBps + (bridge === "sin bridge" ? 0 : P.peer.bridgeBps);
      return `${(bps / 100).toFixed(2)}%`;
    });
    console.log(`| **peer.xyz (hasta)** | — | ${peer.join(" | ")} |`);
    for (const sc of scenarios) {
      for (const d of deals) {
        const cells = P.principals.map((principal) => {
          const base = lines(d.profile, principal, "quiet").reduce((a, l) => a + l.usd, 0);
          const own = (principal * (sc.h + sc.v)) / 10_000;
          const sg = bridge === "sin bridge" ? 0 : (principal * P.stargate.bps) / 10_000 + P.stargate.taxiGasUsd;
          return share(base + own + sg, principal);
        });
        console.log(`| ${sc.name} | ${d.label} | ${cells.join(" | ")} |`);
      }
    }
  }
}

function breakdown(p: Profile, principal: number, m: Market) {
  console.log(`\n### Desglose: ${p.name}, ${principal} tokens, mercado ${m === "quiet" ? "quieto" : "cargado"}\n`);
  console.log("| Quién | Concepto | USD |\n| --- | --- | ---: |");
  for (const l of lines(p, principal, m)) console.log(`| ${l.who} | ${l.what} | ${usd(l.usd)} |`);
}

console.log("# Costo de un deal oficial, como % del principal");
console.log("\nReferencia, peer.xyz (2026-09-28): hasta 0,95% de service fee al taker (el comprador), + el spread que fija el seller.");
console.log("\nFees de paquete y del panel: placeholders, nada decidido. Gas `est`: compuesto de partes medidas.");
summary("quiet");
summary("loaded");
pricing();
breakdown(PROFILES[3], P.principals[0], "quiet");
breakdown(PROFILES[3], P.principals[0], "loaded");
