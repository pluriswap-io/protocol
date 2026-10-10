// The verify lib's suite: the semantic checks (clock, ERC-20 decimals, root liveness,
// mask sanity) run against a STUB proof verifier — CI needs no toolchain — while the
// fixture path runs the REAL pinned bb against the committed attest_base/reveal_advanced
// proof+vk fixtures (the exact path a consumer backend runs), skipped where bb is absent.
//
// The tamper cases are the load-bearing ones: a proof's public inputs are part of the
// Honk statement, so republishing an attestation with an edited pub — an overstated tier,
// a re-targeted requester — must fail at bb verify itself. That is the binding §E.3.15.7
// leans on ("toda stat revelada lleva prueba"), pinned here empirically.

import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  ATTEST_BASE_PUBS,
  AttestBasePubs,
  AttestationEnvelope,
  ProofVerifier,
  REVEAL_ADVANCED_PUBS,
  RevealAdvancedPubs,
  bbVerifier,
  fixtureEnvelope,
  pubInputs,
  readJson,
  splitAttestation,
  verifyAttestationBase,
  verifyAttestationReveal,
} from "./verify.ts";

const REPO = join(import.meta.dir, "../../..");
const BB = join(process.env.PLURI_ZK_BIN ?? join(process.env.HOME ?? "", ".pluri-zk", "bin"), "bb");
const hasBb = existsSync(BB);

const stubOk: ProofVerifier = () => true;
const stubBad: ProofVerifier = () => false;

function baseEnv(over: Partial<AttestBasePubs> = {}): AttestationEnvelope<AttestBasePubs> {
  return {
    proof: "00",
    vk: "00",
    pubs: {
      handle_commit: "123456789",
      tier: "2",
      count: "12",
      volume_band: "2",
      penalty_band: "1",
      expiry: "1800000000",
      token: "97433442488726861213578988847752201310395502865",
      decimals: "6",
      rep_root: "555",
      verified: "1",
      ...over,
    },
  };
}

function revealEnv(over: Partial<RevealAdvancedPubs> = {}): AttestationEnvelope<RevealAdvancedPubs> {
  return {
    proof: "00",
    vk: "00",
    pubs: {
      handle_commit: "123456789",
      fields_mask: "3",
      out_count: "12",
      out_volume: "750000000",
      out_penalty: "5",
      requester: "987654321",
      token: "97433442488726861213578988847752201310395502865",
      rep_root: "555",
      ...over,
    },
  };
}

const clock = { now: 1_700_000_000n };

describe("splitAttestation", () => {
  test("splits proof || pubs and reads the pubs as decimals", () => {
    const blob = Buffer.concat([
      Buffer.from([1, 2, 3]),
      pubInputs(["7", "180000000000000000000000000000000000000000000000000000000000000"]),
    ]).toString("hex");
    const { proof, pubs } = splitAttestation(blob, 2);
    expect(proof).toBe("010203");
    expect(pubs).toEqual(["7", "180000000000000000000000000000000000000000000000000000000000000"]);
  });

  test("rejects a blob too short for its declared pubs", () => {
    expect(() => splitAttestation("00", 2)).toThrow();
  });
});

describe("pubInputs", () => {
  test("writes each pub as a 32-byte big-endian word", () => {
    const out = pubInputs(["0", "1", "256"]);
    expect(out.length).toBe(96);
    expect(out.subarray(0, 32).toString("hex")).toBe("0".repeat(64));
    expect(out.subarray(32, 64).toString("hex")).toBe("0".repeat(62) + "01");
    expect(out.subarray(64, 96).toString("hex")).toBe("0".repeat(60) + "0100");
  });

  test("rejects pubs outside the 32-byte domain", () => {
    expect(() => pubInputs(["" + (1n << 256n)])).toThrow();
  });
});

describe("verifyAttestationBase (semantic checks)", () => {
  test("a fresh, well-formed attestation passes with all cross-checks injected", async () => {
    const r = await verifyAttestationBase(baseEnv(), {
      ...clock,
      verifyProof: stubOk,
      decimalsOf: () => 6n,
      rootAlive: () => true,
    });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("expiry ok");
    expect(r.checks.join(" ")).toContain("decimals cross-checked");
    expect(r.checks.join(" ")).toContain("rep_root is live");
  });

  test("an expired attestation fails on the consumer's clock", async () => {
    const r = await verifyAttestationBase(baseEnv(), { now: 1_900_000_000n, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("expired");
  });

  test("no clock is fail-closed: refuse to verify without one", async () => {
    const r = await verifyAttestationBase(baseEnv(), { verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("no clock");
  });

  test("a bad proof fails before any semantics", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubBad });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("proof verification failed");
  });

  test("a zero handle is not a pseudonym", async () => {
    const r = await verifyAttestationBase(baseEnv({ handle_commit: "0" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("zero handle_commit");
  });

  test("a tier outside the ladder fails", async () => {
    const r = await verifyAttestationBase(baseEnv({ tier: "6" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("ladder");
  });

  test("a verified account says so", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("verified account");
  });

  test("an open account (no Passport) passes at T1 and is named as open", async () => {
    const r = await verifyAttestationBase(baseEnv({ verified: "0", tier: "1" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("open account");
  });

  test("an open account above T1 is not a statement the circuit makes", async () => {
    const r = await verifyAttestationBase(baseEnv({ verified: "0", tier: "2" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("open account above T1");
  });

  test("the flag is a bit", async () => {
    const r = await verifyAttestationBase(baseEnv({ verified: "2" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("not a bit");
  });

  test("the volume band reads as a floor, never as a figure", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubOk });
    expect(r.checks.join(" ")).toContain("1000 tokens+ moved");
  });

  test("a volume band outside the lot ladder fails", async () => {
    const r = await verifyAttestationBase(baseEnv({ volume_band: "6" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("volume_band out of range");
  });

  test("band 0 says under one lot, not zero volume", async () => {
    // The same trap the hidden-field zero is: a fresh account has not moved a lot yet, which is not
    // the same statement as "moved nothing", and the listing must not read as an accusation.
    const r = await verifyAttestationBase(baseEnv({ volume_band: "0" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("under one lot");
  });

  test("the band is read out, labelled by the events behind it", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubOk });
    expect(r.checks.join(" ")).toContain("penalty band 1 (one stalemate or abandoned dispute)");
  });

  test("a band outside the four cuts fails", async () => {
    const r = await verifyAttestationBase(baseEnv({ penalty_band: "4" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("penalty_band out of range");
  });

  test("a clean band is a claim like any other — the circuit, not the lib, proves it", async () => {
    // §E.3.15.7's asymmetry lives in-circuit (`claimed band under the account's`): a zero band
    // over a punished account has no witness. The lib range-checks and reports; it cannot
    // re-derive the direction without the leaf, and does not pretend to.
    const r = await verifyAttestationBase(baseEnv({ penalty_band: "0" }), { ...clock, verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("penalty band 0 (clean)");
  });

  test("a decimals mismatch against the served ERC-20 fails", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubOk, decimalsOf: () => 18n });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("decimals mismatch");
  });

  test("a root the chain never knew fails", async () => {
    const r = await verifyAttestationBase(baseEnv(), { ...clock, verifyProof: stubOk, rootAlive: () => false });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("not live");
  });
});

describe("verifyAttestationReveal (semantic checks)", () => {
  test("a both-fields reveal bound to a requester passes", async () => {
    const r = await verifyAttestationReveal(revealEnv(), { verifyProof: stubOk, rootAlive: () => true });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("bound to the requester");
  });

  test("requester 0 reads as a public reveal, not an error", async () => {
    const r = await verifyAttestationReveal(revealEnv({ requester: "0" }), { verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("public reveal");
  });

  test("a hidden field must read zero", async () => {
    // mask 0b01: count shown, volume hidden — a non-zero volume contradicts its own bit.
    const r = await verifyAttestationReveal(revealEnv({ fields_mask: "1" }), { verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("volume hidden but out_volume non-zero");
  });

  test("the count has its own bit", async () => {
    // mask 0b10: volume shown, count hidden.
    const r = await verifyAttestationReveal(revealEnv({ fields_mask: "2" }), { verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("count hidden but out_count non-zero");
  });

  test("a shown field may legitimately be a true zero", async () => {
    const r = await verifyAttestationReveal(revealEnv({ fields_mask: "3", out_volume: "0" }), { verifyProof: stubOk });
    expect(r.ok).toBeTrue();
  });

  test("the penalty is outside the mask: a profile that hides everything else still states it", async () => {
    // §E.3.15.7: the mask covers count and volume only. A reveal can be published under a handle
    // with no base attestation behind it, so an optional penalty here would reopen the door the
    // mandatory band closed — the circuit asserts `out_penalty == penalty` unconditionally.
    const r = await verifyAttestationReveal(revealEnv({ fields_mask: "0", out_count: "0", out_volume: "0" }), {
      verifyProof: stubOk,
    });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("penalty=always");
    expect(r.checks.join(" ")).toContain("penalty 5 raw (band 1)");
  });

  test("a zero penalty reads as proven clean, not as a hidden field", async () => {
    const r = await verifyAttestationReveal(revealEnv({ out_penalty: "0" }), { verifyProof: stubOk });
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("proven clean");
  });

  test("an unknown mask bit fails", async () => {
    const r = await verifyAttestationReveal(revealEnv({ fields_mask: "4" }), { verifyProof: stubOk });
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("fields_mask out of range");
  });
});

// The real-bb path: the committed fixtures, the pinned toolchain, the exact consumer
// journey (blob -> split -> semantic checks + bb verify). Skipped where bb is absent
// (CI: the proofs are committed fixtures; the toolchain is a developer concern).
describe("verify against the committed fixtures (pinned bb)", () => {
  const attestProof = readJson(join(REPO, "test/fixtures/proofs/attest_base.json")) as {
    proof_with_public_inputs: string;
  };
  const attestVk = readJson(join(REPO, "test/fixtures/vks/attest_base.json")) as { vk: string };
  const revealProof = readJson(join(REPO, "test/fixtures/proofs/reveal_advanced.json")) as {
    proof_with_public_inputs: string;
  };
  const revealVk = readJson(join(REPO, "test/fixtures/vks/reveal_advanced.json")) as { vk: string };

  test.skipIf(!hasBb)("attest_base: the fixture verifies end to end", async () => {
    const env = fixtureEnvelope(attestProof, attestVk, ATTEST_BASE_PUBS.length, ATTEST_BASE_PUBS) as {
      proof: string;
      pubs: AttestBasePubs;
      vk: string;
    };
    expect(env.pubs.tier).toBe("2");
    const r = await verifyAttestationBase({ proof: env.proof, pubs: env.pubs, vk: env.vk }, {
      now: 1_700_000_000n,
      decimalsOf: () => 6n,
      rootAlive: () => true,
    });
    expect(r.ok).toBeTrue();
  });

  test.skipIf(!hasBb)("attest_base: an edited pub (an overstated tier) breaks bb verify", async () => {
    const env = fixtureEnvelope(attestProof, attestVk, ATTEST_BASE_PUBS.length, ATTEST_BASE_PUBS) as {
      proof: string;
      pubs: AttestBasePubs;
      vk: string;
    };
    expect(env.pubs.tier).toBe("2");
    const tampered = { ...env.pubs, tier: "3" };
    expect(await bbVerifier(env.vk)(env.proof, ATTEST_BASE_PUBS.map((n) => tampered[n]))).toBeFalse();
  });

  test.skipIf(!hasBb)("attest_base: an understated penalty band breaks bb verify", async () => {
    // The consumer-side half of the circuit's `claimed band under the account's`. The fixture
    // account absorbed a +5, so its honest band is 1; editing the pub down to a clean 0 is the
    // exact lie the listing must not carry, and the public-input binding refuses it.
    const env = fixtureEnvelope(attestProof, attestVk, ATTEST_BASE_PUBS.length, ATTEST_BASE_PUBS) as {
      proof: string;
      pubs: AttestBasePubs;
      vk: string;
    };
    expect(env.pubs.penalty_band).toBe("1");
    const tampered = { ...env.pubs, penalty_band: "0" };
    expect(await bbVerifier(env.vk)(env.proof, ATTEST_BASE_PUBS.map((n) => tampered[n]))).toBeFalse();
  });

  test.skipIf(!hasBb)("reveal_advanced: the fixture verifies end to end", async () => {
    const env = fixtureEnvelope(revealProof, revealVk, REVEAL_ADVANCED_PUBS.length, REVEAL_ADVANCED_PUBS) as {
      proof: string;
      pubs: RevealAdvancedPubs;
      vk: string;
    };
    expect(env.pubs.fields_mask).toBe("3");
    const r = await verifyAttestationReveal({ proof: env.proof, pubs: env.pubs, vk: env.vk }, {
      rootAlive: () => true,
    });
    expect(r.ok).toBeTrue();
  });

  test.skipIf(!hasBb)("reveal_advanced: a re-targeted requester breaks bb verify", async () => {
    const env = fixtureEnvelope(revealProof, revealVk, REVEAL_ADVANCED_PUBS.length, REVEAL_ADVANCED_PUBS) as {
      proof: string;
      pubs: RevealAdvancedPubs;
      vk: string;
    };
    expect(env.pubs.requester).not.toBe("999");
    const tampered = { ...env.pubs, requester: "999" };
    expect(await bbVerifier(env.vk)(env.proof, REVEAL_ADVANCED_PUBS.map((n) => tampered[n]))).toBeFalse();
  });

  test.skipIf(!hasBb)("reveal_advanced: a zeroed penalty breaks bb verify", async () => {
    // The profile's own non-hideable field: `out_penalty` is not masked, so a reveal claiming a
    // clean history against the punished fixture account has no proof — the same statement the
    // band makes on the listing, made exactly instead of as an aggregate.
    const env = fixtureEnvelope(revealProof, revealVk, REVEAL_ADVANCED_PUBS.length, REVEAL_ADVANCED_PUBS) as {
      proof: string;
      pubs: RevealAdvancedPubs;
      vk: string;
    };
    expect(env.pubs.out_penalty).not.toBe("0");
    const tampered = { ...env.pubs, out_penalty: "0" };
    expect(await bbVerifier(env.vk)(env.proof, REVEAL_ADVANCED_PUBS.map((n) => tampered[n]))).toBeFalse();
  });
});
