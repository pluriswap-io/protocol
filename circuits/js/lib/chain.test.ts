// The chain lib's suite: pure logic against a stub verifier — the consistency semantics
// a consumer's cadence policy sits on (one handle, raw monotonicity), plus the two
// negative shapes the design says must REJECT (a spliced series, a decreasing counter).

import { describe, expect, test } from "bun:test";
import { ChainElement, verifyAttestationChain } from "./chain.ts";
import { AttestBasePubs, RevealAdvancedPubs } from "./verify.ts";

const clock = { now: 1_700_000_000n, verifyProof: () => true } as const;

function base(pubs: Partial<AttestBasePubs>): ChainElement {
  return {
    kind: "base",
    proof: "00",
    vk: "00",
    pubs: {
      handle_commit: "777",
      tier: "2",
      count: "12",
      volume_band: "2",
      penalty_band: "1",
      expiry: "1800000000",
      token: "1",
      decimals: "6",
      rep_root: "555",
      verified: "1",
      ...pubs,
    },
  };
}

function reveal(pubs: Partial<RevealAdvancedPubs>): ChainElement {
  return {
    kind: "reveal",
    proof: "00",
    vk: "00",
    pubs: {
      handle_commit: "777",
      fields_mask: "3",
      out_count: "12",
      out_volume: "750000000",
      out_penalty: "5",
      requester: "42",
      token: "1",
      rep_root: "555",
      ...pubs,
    },
  };
}

describe("verifyAttestationChain", () => {
  test("an empty chain discloses nothing", async () => {
    const r = await verifyAttestationChain([], clock);
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("empty chain");
  });

  test("a single element is a (trivial) consistent chain", async () => {
    const r = await verifyAttestationChain([base({})], clock);
    expect(r.ok).toBeTrue();
  });

  test("a count that grows across attestations is the honest trajectory", async () => {
    const r = await verifyAttestationChain([base({ count: "12" }), base({ count: "15" })], clock);
    expect(r.ok).toBeTrue();
    expect(r.checks.join(" ")).toContain("one handle across 2 elements");
  });

  test("a decreasing count is a fabricated series — count never decreases (§E.3.15.5)", async () => {
    const r = await verifyAttestationChain([base({ count: "15" }), base({ count: "12" })], clock);
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("count 12 decreased from 15");
  });

  test("two handles spliced into one series fail as one account's disclosure", async () => {
    const r = await verifyAttestationChain(
      [base({}), base({ handle_commit: "888" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("handle_commit differs");
  });

  test("an open account that verifies later is an honest series", async () => {
    const r = await verifyAttestationChain(
      [base({ verified: "0", tier: "1", count: "3" }), base({ verified: "1", tier: "1", count: "4" })],
      clock,
    );
    expect(r.ok).toBeTrue();
  });

  test("an account is never un-verified: open after verified is a fabrication", async () => {
    const r = await verifyAttestationChain(
      [base({ verified: "1", tier: "1" }), base({ verified: "0", tier: "1" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("never un-verified");
  });

  test("revealed volume and penalty track monotone across reveals", async () => {
    const r = await verifyAttestationChain(
      [reveal({ out_volume: "750000000", out_penalty: "5" }), reveal({ out_volume: "900000000", out_penalty: "5" })],
      clock,
    );
    expect(r.ok).toBeTrue();
  });

  test("a decreasing revealed penalty is a fabricated series", async () => {
    const r = await verifyAttestationChain(
      [reveal({ out_penalty: "10" }), reveal({ out_penalty: "5" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("penalty 5 decreased from 10");
  });

  test("a hidden field does not participate in the track (mask 0b10 hides the count)", async () => {
    const r = await verifyAttestationChain(
      [
        reveal({ fields_mask: "3", out_count: "20", out_volume: "900000000", out_penalty: "5" }),
        reveal({ fields_mask: "2", out_count: "0", out_volume: "900000000", out_penalty: "5" }), // count hidden
      ],
      clock,
    );
    expect(r.ok).toBeTrue();
  });

  test("the reveal's count is the SAME counter the listing claims", async () => {
    // §E.3.15.7's two views of one account: `out_count` and `count` read the same leaf field, so
    // a reveal that walks it back after a listing already claimed it is a fabricated series.
    const r = await verifyAttestationChain(
      [base({ count: "12" }), reveal({ out_count: "9" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("count 9 decreased from 12");
  });

  test("the penalty tracks even when the chosen fields are all withheld", async () => {
    // The mask no longer covers the penalty, so hiding everything else does not hide it —
    // and the monotonicity check keeps working on a series of otherwise empty profiles.
    const r = await verifyAttestationChain(
      [
        reveal({ fields_mask: "0", out_count: "0", out_volume: "0", out_penalty: "10" }),
        reveal({ fields_mask: "0", out_count: "0", out_volume: "0", out_penalty: "5" }),
      ],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("penalty 5 decreased from 10");
  });

  test("a listing cannot claim a band under a penalty the same series already revealed", async () => {
    // The cross-check that makes the aggregate honest: the reveal states 20 raw (band 3), so a
    // later listing claiming band 1 contradicts evidence its own author handed over.
    const r = await verifyAttestationChain(
      [reveal({ out_penalty: "20" }), base({ penalty_band: "1" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("penalty band 1 under band 3");
  });

  test("a band OVER the revealed penalty is allowed — overstating only costs its author", async () => {
    const r = await verifyAttestationChain(
      [reveal({ out_penalty: "5" }), base({ penalty_band: "3" })],
      clock,
    );
    expect(r.ok).toBeTrue();
  });

  test("a volume band that walks backwards is a fabricated series", async () => {
    const r = await verifyAttestationChain([base({ volume_band: "3" }), base({ volume_band: "1" })], clock);
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("volume band 1 decreased from 3");
  });

  test("a volume band that climbs is the honest trajectory", async () => {
    const r = await verifyAttestationChain([base({ volume_band: "1" }), base({ volume_band: "3" })], clock);
    expect(r.ok).toBeTrue();
  });

  test("a mixed series: count tracks across reveals, reveals track their fields", async () => {
    const r = await verifyAttestationChain(
      [
        base({ count: "12" }),
        reveal({ out_volume: "750000000", out_penalty: "5" }),
        base({ count: "12", tier: "1" }), // a mid-chain penalty may drop the tier — honest
      ],
      clock,
    );
    expect(r.ok).toBeTrue();
  });

  test("a mixed series with a count that drops after a reveal still fails", async () => {
    const r = await verifyAttestationChain(
      [base({ count: "12" }), reveal({}), base({ count: "10" })],
      clock,
    );
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("count 10 decreased from 12");
  });

  test("a failing element's own errors ride into the chain result", async () => {
    const r = await verifyAttestationChain([base({}), base({ expiry: "100" })], clock);
    expect(r.ok).toBeFalse();
    expect(r.errors.join(" ")).toContain("element 1: attestation expired");
  });
});
