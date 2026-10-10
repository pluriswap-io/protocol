// BN254 scalar field helpers (PROTOCOLO.md §E.3.15.3). The field is the domain of every
// commitment, nullifier and tree node of the private layer; this module is the single
// place that knows the modulus and the pinned encoding rules.
//
// Pinned rules (PROTOCOLO.md §E.3.15.3, as amended by the canonical-encoding decision):
//  * any bytes32 that enters a Poseidon input is interpreted mod P — keccak-derived IDs
//    (dealId, registryId, salts) routinely exceed the ~253.6-bit field, and both
//    poseidon-solidity (mulmod/addmod) and Noir (native Field arithmetic) reduce
//    implicitly. The adapters reduce explicitly before assembling public inputs.
//  * amounts are range-checked < 2^128 in-circuit; adapters fail closed on any
//    public input >= P (a canonical field element is never >= P).

import { keccak256 } from "js-sha3";

export const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Reduces `x` into the field (explicit form of the pinned mod-p rule). */
export function modP(x: bigint): bigint {
  return ((x % P) + P) % P;
}

/** Canonical decimal string of a field element (the vectors.json encoding). */
export function dec(x: bigint): string {
  return x.toString(10);
}

/** Parses a decimal or 0x-hex string into a field element, reduced mod P. */
export function field(s: string): bigint {
  return modP(BigInt(s));
}

/** 32-byte little-endian Montgomery limbs (ffjavascript Fr output) to a canonical field element. */
export function fromMontgomeryLE(bytes: Uint8Array): bigint {
  let m = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) {
    m = (m << 8n) | BigInt(bytes[i]);
  }
  return modP(m * R_INV);
}

// ffjavascript's bn128 Fr uses Montgomery form with R = 2^256 mod P; circomlibjs returns
// the raw internal bytes, so the twin multiplies by R^-1 once per output.
const R_INV = 9915499612839321149637521777990102151350674507940716049588462388200839649614n;

/** keccak256 of an ascii string as a 0x-prefixed hex string (test sample values only).
 *  The EVM's keccak256 — the pre-NIST Keccak padding (0x01), NOT node's "sha3-256" (0x06). */
export function keccak(s: string): string {
  return "0x" + keccak256(s);
}
