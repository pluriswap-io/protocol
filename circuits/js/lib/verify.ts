// The consumer-side verification surface of the disclosure layer (PROTOCOLO.md §E.3.15.7,
// F4 as-built). The Labs backend — or any consumer — verifies an attestation OFF-CHAIN
// with the pinned bb, then applies the semantic checks the circuit cannot make:
//
//   * the CLOCK: `expiry >= now` (the circuit has no notion of time; §E.3.15.7's freshness
//     model is the consumer's policy, so the clock lives here);
//   * the ERC-20: the claimed `decimals` against the served token's `decimals()` (the
//     tier is a function of both — the circuit binds the pair, the consumer binds the
//     token to its chain reality);
//   * the ROOT: `repRoot` against the account tree's live roots (`isKnownRoot` is a
//     public read of PoseidonTree) — a proof against a root the chain never knew is a
//     true statement about a state that never existed.
//
// No contracts are involved: `verifyAttestation*` returns a RESULT (ok + errors + the
// checks that ran), never a bare boolean — the consumer prices WHY, not just whether.
//
// The proof check itself is injectable (`opts.verifyProof`): the default spawns the
// pinned `bb verify` (the same binary prove.ts uses); a future bb.js/WASM verifier (or
// a test stub) slots in without touching the semantic layer.

import { execSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { penaltyBand, volumeBandFloor } from "./tiers.ts";

/** The pub orders, exactly as the circuits declare them (the fixture blob's tail). */
export const ATTEST_BASE_PUBS = [
  "handle_commit",
  "tier",
  "count",
  "volume_band",
  "penalty_band",
  "expiry",
  "token",
  "decimals",
  "rep_root",
  "verified",
] as const;
export const REVEAL_ADVANCED_PUBS = [
  "handle_commit",
  "fields_mask",
  "out_count",
  "out_volume",
  "out_penalty",
  "requester",
  "token",
  "rep_root",
] as const;

export type AttestBasePubs = {
  handle_commit: string;
  tier: string;
  count: string;
  /** The §E.3.15.7 aggregate: 0 clean, 1 (1..5), 2 (6..15), 3 (16+). Cannot be understated. */
  volume_band: string;
  penalty_band: string;
  expiry: string;
  token: string;
  decimals: string;
  rep_root: string;
  /** The account's own flag (2026-10-01): 1 when a proof of humanity stands behind it, 0 for an open
   *  account. Exact, not a bound — the leaf commits to it. */
  verified: string;
};
export type RevealAdvancedPubs = {
  handle_commit: string;
  fields_mask: string;
  out_count: string;
  out_volume: string;
  /** Raw and unconditional -- outside the mask by construction. */
  out_penalty: string;
  requester: string;
  token: string;
  rep_root: string;
};

/** `proof || pubs` — the raw blob a prover hands a consumer (the adapters' own format). */
export type AttestationEnvelope<E> = { proof: string; pubs: E; vk: string };

/** A proof checker: given the proof hex and the decimal pub strings, is the proof valid? */
export type ProofVerifier = (proof: string, pubs: string[]) => boolean | Promise<boolean>;

export type VerifyOpts = {
  /** The consumer's clock (unix seconds). REQUIRED for attest_base (its expiry check). */
  now?: bigint;
  /** The served token's `decimals()` — inject the ERC-20 read; when absent the decimals
   *  cross-check is skipped and the result says so. */
  decimalsOf?: (token: bigint) => bigint | Promise<bigint>;
  /** Live-root check against the chain (e.g. `isKnownRoot`); when absent it is skipped. */
  rootAlive?: (root: bigint) => boolean | Promise<boolean>;
  /** The proof check; defaults to the pinned `bb verify` spawn. */
  verifyProof?: ProofVerifier;
};

export type VerifyResult = { ok: boolean; errors: string[]; checks: string[] };

// ---------------------------------------------------------------- blob plumbing

/** Split `proof || public_inputs` (bare hex) into the proof hex and the decimal pub
 *  strings — the adapter split, in the consumer's hands. */
export function splitAttestation(blob: string, nPubs: number): { proof: string; pubs: string[] } {
  const bytes = Buffer.from(blob, "hex");
  if (bytes.length <= nPubs * 32) {
    throw new Error(`blob too short for ${nPubs} public inputs (${bytes.length} bytes)`);
  }
  const proof = bytes.subarray(0, bytes.length - nPubs * 32);
  const pubBytes = bytes.subarray(bytes.length - nPubs * 32);
  const pubs: string[] = [];
  for (let i = 0; i < nPubs; i++) {
    pubs.push(BigInt(`0x${pubBytes.subarray(i * 32, (i + 1) * 32).toString("hex")}`).toString(10));
  }
  return { proof: proof.toString("hex"), pubs };
}

/** The pub vector as bb consumes it: each decimal string a 32-byte big-endian word. */
export function pubInputs(pubs: string[]): Buffer {
  const out = Buffer.alloc(pubs.length * 32);
  pubs.forEach((p, i) => {
    const n = BigInt(p);
    if (n < 0n || n >= 1n << 256n) throw new Error(`pub out of 32-byte range: ${p}`);
    const hex = n.toString(16).padStart(64, "0");
    Buffer.from(hex, "hex").copy(out, i * 32);
  });
  return out;
}

// ---------------------------------------------------------------- the bb default

const BB = join(process.env.PLURI_ZK_BIN ?? join(process.env.HOME ?? "", ".pluri-zk", "bin"), "bb");

/** The default proof verifier: the pinned `bb verify` (same binary, same flags as
 *  prove.ts). Writes a temp triple (vk, proof, public_inputs) and expects bb's ok. */
export function bbVerifier(vkHex: string): ProofVerifier {
  return (proofHex, pubs) => {
    if (!existsSync(BB)) {
      throw new Error(`bb not found at ${BB} — install the pinned toolchain (circuits/README.md) or inject opts.verifyProof`);
    }
    const dir = mkdtempSync(join(tmpdir(), "pluri-attest-"));
    try {
      writeFileSync(join(dir, "vk"), Buffer.from(vkHex, "hex"));
      writeFileSync(join(dir, "proof"), Buffer.from(proofHex, "hex"));
      writeFileSync(join(dir, "public_inputs"), pubInputs(pubs));
      const out = execSync(`${BB} verify -k ${join(dir, "vk")} -p ${join(dir, "proof")} -i ${join(dir, "public_inputs")} -t evm 2>&1`, {
        stdio: ["ignore", "pipe", "pipe"],
      }).toString();
      return out.includes("Proof verified successfully");
    } catch (e) {
      // bb exits non-zero on a bad proof (its own message is the diagnostic).
      return false;
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };
}

// ---------------------------------------------------------------- semantic checks

/** The §E.3.15.7 volume band, as a listing renders it: the floor in WHOLE tokens, or the honest
 *  nothing-yet for band 0. The caller supplies the symbol — the proof carries the token's address,
 *  not its name, and inventing one is exactly the kind of claim this lib does not make. */
export function volumeBandLabel(band: number, symbol = "tokens"): string {
  const floor = volumeBandFloor(band);
  return floor === null ? `under one lot moved (250 ${symbol})` : `${floor} ${symbol}+ moved`;
}

/** The §E.3.15.7 bands, as a consumer reads them: the cuts are events (+5 a stalemate or an
 *  abandoned dispute, +15 an arbitration loss), so the label is the history, not a grade. */
export const PENALTY_BAND_LABELS = [
  "clean",
  "one stalemate or abandoned dispute",
  "several, or one loss at a tribunal",
  "more than one loss",
] as const;

function result(errors: string[], checks: string[]): VerifyResult {
  return { ok: errors.length === 0, errors, checks };
}

/** Parse the decimal pubs into the named shape, in the circuit's declared order. */
function named(names: readonly string[], pubs: Record<string, string>): string[] {
  return names.map((n) => {
    const v = pubs[n];
    if (v === undefined) throw new Error(`missing pub: ${n}`);
    return v;
  });
}

export async function verifyAttestationBase(
  att: AttestationEnvelope<AttestBasePubs>,
  opts: VerifyOpts,
): Promise<VerifyResult> {
  const errors: string[] = [];
  const checks: string[] = [];
  const verifyProof = opts.verifyProof ?? bbVerifier(att.vk);
  const pubs = named(ATTEST_BASE_PUBS, att.pubs as Record<string, string>);

  if (await verifyProof(att.proof, pubs)) {
    checks.push("proof verified");
  } else {
    errors.push("proof verification failed");
  }

  // The clock: §E.3.15.7's freshness is the consumer's policy, so `now` is required here —
  // refusing to verify without a clock is the fail-closed direction.
  if (opts.now === undefined) {
    errors.push("no clock: opts.now is required (the expiry check is the consumer's)");
  } else if (BigInt(att.pubs.expiry) < opts.now) {
    errors.push(`attestation expired: expiry ${att.pubs.expiry} < now ${opts.now}`);
  } else {
    checks.push(`expiry ok (expiry ${att.pubs.expiry} >= now ${opts.now})`);
  }

  if (BigInt(att.pubs.handle_commit) === 0n) {
    errors.push("zero handle_commit");
  }

  const tier = BigInt(att.pubs.tier);
  if (tier < 1n || tier > 5n) {
    errors.push(`tier out of the ladder: ${att.pubs.tier}`);
  }

  // The flag (2026-10-01). The count and the volume band below are the account's RECORD — every
  // completed deal — and the tier is its CREDIT, which only verified accounts earn, once per
  // counterparty. So the flag is what tells a reader how far the record speaks for the account: an open
  // account's record is real deals, but nobody's humanity stands behind the counterparties that made it.
  const verified = BigInt(att.pubs.verified);
  if (verified !== 0n && verified !== 1n) {
    errors.push(`verified is not a bit: ${att.pubs.verified}`);
  } else if (verified === 1n) {
    checks.push("verified account (a proof of humanity stands behind it)");
  } else {
    // An open account earns no credit, so its tier is T1 by construction: a proof that says otherwise
    // is not one the circuit can produce, and the lib says so rather than rendering it.
    if (tier > 1n) errors.push(`an open account above T1: tier ${att.pubs.tier}`);
    checks.push("open account (no Passport): its record counts deals, its tier stays T1");
  }

  // The volume band (§E.3.15.7): a floor like tier and count — the circuit proves the account is at
  // least here, so the lib range-checks it and states it as a floor, never as a figure.
  const vband = BigInt(att.pubs.volume_band);
  if (vband < 0n || vband > 5n) {
    errors.push(`volume_band out of range: ${att.pubs.volume_band}`);
  } else {
    checks.push(`volume ${volumeBandLabel(Number(vband))}`);
  }

  // The band (§E.3.15.7): mandatory and never understated — the circuit asserts the claimed
  // band COVERS the account's, the opposite direction from tier/count. Here the lib only
  // range-checks it and names it, because the direction is already proven.
  const band = BigInt(att.pubs.penalty_band);
  if (band < 0n || band > 3n) {
    errors.push(`penalty_band out of range: ${att.pubs.penalty_band}`);
  } else {
    checks.push(`penalty band ${band} (${PENALTY_BAND_LABELS[Number(band)]})`);
  }

  if (opts.decimalsOf) {
    if ((await opts.decimalsOf(BigInt(att.pubs.token))) === BigInt(att.pubs.decimals)) {
      checks.push("decimals cross-checked against the ERC-20");
    } else {
      errors.push(`decimals mismatch: proof claims ${att.pubs.decimals} for token ${att.pubs.token}`);
    }
  } else {
    checks.push("decimals cross-check skipped (no decimalsOf injected)");
  }

  if (opts.rootAlive) {
    if (await opts.rootAlive(BigInt(att.pubs.rep_root))) {
      checks.push("rep_root is live");
    } else {
      errors.push(`rep_root not live: ${att.pubs.rep_root}`);
    }
  } else {
    checks.push("root liveness skipped (no rootAlive injected)");
  }

  return result(errors, checks);
}

export async function verifyAttestationReveal(
  att: AttestationEnvelope<RevealAdvancedPubs>,
  opts: VerifyOpts,
): Promise<VerifyResult> {
  const errors: string[] = [];
  const checks: string[] = [];
  const verifyProof = opts.verifyProof ?? bbVerifier(att.vk);
  const pubs = named(REVEAL_ADVANCED_PUBS, att.pubs as Record<string, string>);

  if (await verifyProof(att.proof, pubs)) {
    checks.push("proof verified");
  } else {
    errors.push("proof verification failed");
  }

  if (BigInt(att.pubs.handle_commit) === 0n) {
    errors.push("zero handle_commit");
  }

  const mask = Number(BigInt(att.pubs.fields_mask));
  if (mask < 0 || mask > 3) {
    errors.push(`fields_mask out of range: ${att.pubs.fields_mask}`);
  } else {
    // The lib mirrors the circuit's own mask semantics where it can: a HIDDEN field
    // (bit clear) must read zero. A shown field may legitimately be zero (a true zero).
    if (!(mask & 1) && BigInt(att.pubs.out_count) !== 0n) {
      errors.push("count hidden but out_count non-zero");
    }
    if (!(mask & 2) && BigInt(att.pubs.out_volume) !== 0n) {
      errors.push("volume hidden but out_volume non-zero");
    }
    // The penalty is OUTSIDE the mask (§E.3.15.7): the advanced reveal states the raw counter
    // whatever else it withholds, so there is no bit to check — only the reading below.
    checks.push(`fields revealed: count=${!!(mask & 1)} volume=${!!(mask & 2)} penalty=always`);
    checks.push(
      BigInt(att.pubs.out_penalty) === 0n
        ? "penalty 0 — proven clean (the circuit forbids hiding it behind a zero)"
        : `penalty ${att.pubs.out_penalty} raw (band ${penaltyBand(BigInt(att.pubs.out_penalty))})`,
    );
  }

  checks.push(
    BigInt(att.pubs.requester) === 0n
      ? "public reveal (requester 0 — anyone may read it)"
      : "bound to the requester's pubkey hash",
  );

  if (opts.rootAlive) {
    if (await opts.rootAlive(BigInt(att.pubs.rep_root))) {
      checks.push("rep_root is live");
    } else {
      errors.push(`rep_root not live: ${att.pubs.rep_root}`);
    }
  } else {
    checks.push("root liveness skipped (no rootAlive injected)");
  }

  return result(errors, checks);
}

/** The committed fixtures, as a consumer envelope: split the blob, name the pubs, read
 *  the vk. The tamper/fixture tests of the bun suite run exactly this path. */
export function fixtureEnvelope(
  proofFixture: { proof_with_public_inputs: string },
  vkFixture: { vk: string },
  nPubs: number,
  names: readonly string[],
): { proof: string; pubs: Record<string, string>; vk: string } {
  const { proof, pubs } = splitAttestation(proofFixture.proof_with_public_inputs, nPubs);
  const namedPubs: Record<string, string> = {};
  names.forEach((n, i) => (namedPubs[n] = pubs[i]));
  return { proof, pubs: namedPubs, vk: vkFixture.vk };
}

export function readJson(path: string): { [k: string]: unknown } {
  return JSON.parse(readFileSync(path, "utf8"));
}
