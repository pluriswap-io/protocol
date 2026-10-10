// The proof-fixture generator of the private layer (PROTOCOLO.md §E.3.15.9): runs the pinned
// toolchain (nargo + bb, see circuits/README.md) end to end for the circuits of the current
// phase and writes, per circuit:
//
//   * crates/<circuit>/Prover.toml      — the witness, from the registry and prepare
//                                         sections of test/fixtures/vectors.json (all
//                                         keccak-derived inputs REDUCED mod p: nargo
//                                         rejects raw values >= p, so the prover boundary
//                                         is where the pinned mod-p rule reduces);
//   * test/fixtures/proofs/<name>.json — {"proof_with_public_inputs": <bare hex of proof ||
//                                         public_inputs>} (the exact blob the adapters split;
//                                         BARE hex because vm.parseJsonBytes prepends its
//                                         own "0x" — a prefixed value double-prefixes and
//                                         fails to parse);
//   * verifiers/src/<C>.sol              — the bb-generated optimized Honk verifier, its
//                                         contract renamed per circuit (two generated files
//                                         cannot both declare `HonkVerifier` in one solc
//                                         invocation), COMMITTED in the self-contained
//                                         `verifiers/` project (via_ir off — the generated
//                                         dispatchers do not compile under the main tree's
//                                         via_ir, and the main tree needs it);
//   * test/fixtures/verifiers/<name>.json — {"initcode": <bare hex>} — the verifier INITCODE,
//                                         extracted from the verifiers project artifact. The
//                                         adapters deploy from it; nothing in the main build
//                                         links the generated contracts.
//
// Every step asserts success (bb verify natively, contract renames, artifact extraction):
// a fixture that would silently drift is worse than no fixture. Committed outputs mean CI
// never needs this toolchain. The witness, public inputs, verifier contracts and initcode
// are byte-deterministic across runs; the PROOF itself is not (fresh ZK blinding per
// prove — each run's fixture is a different valid proof of the same statement).
//
// Run: bun circuits:prove            (every circuit)
//      bun circuits:prove claim      (only the named circuits — the others' fixtures stay as they
//                                     are, instead of each being re-proven with fresh blinding)

import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { P, modP } from "./lib/fields.ts";

const REPO = join(import.meta.dir, "../..");
const CIRCUITS = join(REPO, "circuits");
const BIN = process.env.PLURI_ZK_BIN ?? join(process.env.HOME ?? "", ".pluri-zk/bin");

// ---------------------------------------------------------------- the circuits (one row each)

type Circuit = {
  /** the fixture's name — and the nargo package (crates/<name>), unless `crate` names another */
  name: string;
  /** a SECOND sample of an existing circuit (2026-10-01: the open-account shapes): the nargo package it
   *  proves, under its own Prover file and fixture name. A variant writes a proof fixture only — the
   *  verifier, its initcode and the VK are the package's, already written by its main row. */
  crate?: string;
  /** the Solidity verifier contract this circuit's vk generates — undefined for the
   *  off-chain circuits (F4): no EVM verifier is written, the VK itself is the fixture */
  contract?: string;
  /** public input count in the proof blob (order = the circuit's pub signature order) */
  pubs: number;
  /** off-chain circuit (F4): verify with bb / bb.js, commit the vk instead of initcode */
  offchain?: boolean;
  /** Prover.toml content, from the vectors fixture (reduced where keccak-derived) */
  proverToml: (v: Vectors) => string;
};

type RegistryVectors = {
  depth: number;
  registry_id: string;
  hsk: string;
  identity_commitment: string;
  empty_root: string;
  siblings: string[];
  indices: number[];
  root: string;
  sample_hn: string;
  sample_sk_id: string;
  sample_s: string;
  sample_leaf0: string;
};

type PrepareVectors = {
  cp_root: string;
  cp_s: string;
  pair_tag: string;
  pair_secret: string;
  registry_id: string;
  hint_s: string;
  hint_k: string;
  arbiters: string[];
  pool_id: string;
  operator_tag: string;
  pool_cp_tag: string;
  depth: number;
  decimals: string;
  principal: string;
  token: string;
  sk_id: string;
  deal_id: string;
  salt: string;
  new_salt: string;
  s: string;
  leaf0: string;
  siblings: string[];
  indices: number[];
  root: string;
  deal_subject: string;
  null_rep: string;
  new_leaf: string;
  score: string;
  cap: string;
};

type DepositVectors = { token: string; amount: string; note: string; sk_id: string; index: string; salt: string };

type BondVectors = {
  deal_id: string;
  deal_subject: string;
  token: string;
  note_amount: string;
  source_salt: string;
  lock_amount: string;
  lock_salt: string;
  change_salt: string;
  lock_commit: string;
  change_note: string;
  null_bond: string;
  siblings: string[];
  indices: number[];
  root: string;
  sk_id: string;
};

type ClaimVectors = {
  rec_count: string;
  rec_volume: string;
  verified: string;
  credit: string;
  deal_id: string;
  deal_subject: string;
  kind: string;
  token: string;
  principal: string;
  sk_id: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  new_salt: string;
  cp_root: string;
  epoch: string;
  epoch_credits: string;
  cp_s: string;
  cp_siblings: string[];
  pair_tag: string;
  pair_secret: string;
  claim_epoch: string;
  new_leaf: string;
  null_rep: string;
  siblings: string[];
  indices: number[];
  root: string;
};

type ReabsorbVectors = {
  deal_id: string;
  deal_subject: string;
  token: string;
  amount: string;
  kept: string;
  cut_kept: string;
  cut_new_note: string;
  lock_commit: string;
  lock_salt: string;
  new_salt: string;
  new_note: string;
  null_bond: string;
  sk_id: string;
};

type WithdrawVectors = {
  token: string;
  dest: string;
  amount: string;
  note_amount: string;
  source_salt: string;
  change_salt: string;
  change_note: string;
  null_bond: string;
  siblings: string[];
  indices: number[];
  root: string;
  sk_id: string;
};

type AttestVectors = {
  rec_count: string;
  rec_volume: string;
  verified: string;
  sk_id: string;
  handle_salt: string;
  handle_commit: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  token: string;
  decimals: string;
  tier: string;
  count_claimed: string;
  cp_root: string;
  epoch: string;
  epoch_credits: string;
  volume_band: string;
  penalty_band: string;
  expiry: string;
  root: string;
  siblings: string[];
  indices: number[];
};

type RevealVectors = {
  rec_count: string;
  rec_volume: string;
  verified: string;
  handle_commit: string;
  fields_mask: string;
  out_count: string;
  cp_root: string;
  epoch: string;
  epoch_credits: string;
  out_volume: string;
  out_penalty: string;
  requester: string;
  token: string;
  sk_id: string;
  handle_salt: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  root: string;
  siblings: string[];
  indices: number[];
};

type SideVectorsP = {
  lock_commit: string;
  lock_amount: string;
  change_note: string;
  null_bond: string;
  bond_root: string;
  note_amount: string;
  source_salt: string;
  note_siblings: string[];
  note_indices: number[];
};

type Vectors = {
  registry: RegistryVectors;
  prepare: PrepareVectors;
  deposit: DepositVectors;
  bond: BondVectors;
  claim: ClaimVectors;
  reabsorb: ReabsorbVectors;
  withdraw: WithdrawVectors;
  side: SideVectorsP;
  attest: AttestVectors;
  reveal: RevealVectors;
  /** The open account of 2026-10-01 (vectors.ts `open`). */
  open: {
    sk_id: string;
    leaf0: string;
    root: string;
    siblings: string[];
    indices: number[];
    deal_subject: string;
    null_rep: string;
    new_leaf: string;
    cp_s: string;
    cp_siblings: string[];
    cp_root: string;
    pair_tag: string;
    hint_s: string;
    hint_k: string;
    claim_root: string;
    claim_siblings: string[];
    claim_indices: number[];
    claim_null_rep: string;
    claim_new_leaf: string;
    upgrade_hn: string;
    upgrade_new_leaf: string;
  };
};

const CIRCUIT_LIST: Circuit[] = [
  {
    name: "register_humanity",
    contract: "RegisterHumanityVerifier",
    pubs: 3,
    proverToml: (v) =>
      toml([
        `h_n = ${str(v.registry.sample_hn)}`,
        `root = ${str(v.registry.root)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `hsk = ${str(modP(BigInt(v.registry.hsk)))}`,
        `siblings = [${v.registry.siblings.map(str).join(", ")}]`,
        `indices = [${v.registry.indices.join(", ")}]`,
      ]),
  },
  {
    name: "register_account",
    contract: "RegisterAccountVerifier",
    pubs: 4,
    proverToml: (v) =>
      toml([
        `h_n = ${str(v.registry.sample_hn)}`,
        `leaf0 = ${str(v.registry.sample_leaf0)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `verified = "1"`,
        `hsk = ${str(modP(BigInt(v.registry.hsk)))}`,
        `sk_id = ${str(v.registry.sample_sk_id)}`,
      ]),
  },
  {
    // An open account's registration (2026-10-01): no human, no nullifier, a genesis that says so.
    name: "register_account_open",
    crate: "register_account",
    pubs: 4,
    proverToml: (v) =>
      toml([
        `h_n = "0"`,
        `leaf0 = ${str(v.open.leaf0)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `verified = "0"`,
        `hsk = "0"`,
        `sk_id = ${str(v.open.sk_id)}`,
      ]),
  },
  {
    // The open account verified in place by the registry sample human (2026-10-01).
    name: "upgrade_account",
    contract: "UpgradeAccountVerifier",
    pubs: 5,
    proverToml: (v) =>
      toml([
        `h_n = ${str(v.open.upgrade_hn)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `rep_root = ${str(v.open.root)}`,
        `nullifier = ${str(v.open.null_rep)}`,
        `new_leaf = ${str(v.open.upgrade_new_leaf)}`,
        `hsk = ${str(modP(BigInt(v.registry.hsk)))}`,
        `sk_id = ${str(v.open.sk_id)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.open.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `siblings = [${v.open.siblings.map(str).join(", ")}]`,
        `indices = [${v.open.indices.join(", ")}]`,
      ]),
  },
  {
    // Merged into `prepare_side` (§E.3.15.4, 2026-09-23): the statement still has a circuit of its
    // own, and its tests still pin it, but nothing verifies it on chain any more.
    name: "prepare_passport",
    offchain: true,
    pubs: 2,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.prepare.deal_subject)}`,
        `rep_root = ${str(v.prepare.root)}`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        // The account's current leaf is the registered genesis leaf0: all counters zero,
        // token zero, salt = the reduced hsk, version zero.
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.prepare.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `verified = "1"`,
        `siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `indices = [${v.prepare.indices.join(", ")}]`,
      ]),
  },
  {
    // Merged into `prepare_side` (§E.3.15.4, 2026-09-23): the statement still has a circuit of its
    // own, and its tests still pin it, but nothing verifies it on chain any more.
    name: "prepare_admit",
    offchain: true,
    pubs: 9,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.prepare.deal_subject)}`,
        `new_leaf = ${str(v.prepare.new_leaf)}`,
        `nullifier = ${str(v.prepare.null_rep)}`,
        `token = ${str(v.prepare.token)}`,
        `principal = ${str(v.prepare.principal)}`,
        // V2 has no vault: the base cap column, lockCommit identically zero.
        `lock_commit = "0"`,
        `rep_root = ${str(v.prepare.root)}`,
        `decimals = ${str(v.prepare.decimals)}`,
        `pair_tag = ${str(v.prepare.pair_tag)}`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        `s_other = ${str(v.prepare.cp_s)}`,
        `pair_secret = ${str(v.prepare.pair_secret)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.prepare.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `verified = "1"`,
        `siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `indices = [${v.prepare.indices.join(", ")}]`,
      ]),
  },
  {
    // The merged side (§E.3.15.4, 2026-09-23): the three per-module statements of one side in one
    // proof, verified once by the shared `BundleVerifier`.
    name: "prepare_side",
    contract: "PrepareSideVerifier",
    pubs: 21,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.prepare.deal_subject)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        `token = ${str(v.prepare.token)}`,
        `principal = ${str(v.prepare.principal)}`,
        `decimals = ${str(v.prepare.decimals)}`,
        `rep_root = ${str(v.prepare.root)}`,
        `new_leaf = ${str(v.prepare.new_leaf)}`,
        `nullifier = ${str(v.prepare.null_rep)}`,
        `pair_tag = ${str(v.prepare.pair_tag)}`,
        // The bonded shape: the same deal's lock and the change of the deposited note.
        `lock_commit = ${str(v.side.lock_commit)}`,
        `lock_amount = ${str(v.side.lock_amount)}`,
        `change_note = ${str(v.side.change_note)}`,
        `null_bond_out = ${str(v.side.null_bond)}`,
        `bond_root = ${str(v.side.bond_root)}`,
        `registry_id = ${str(v.prepare.registry_id)}`,
        `hint_s = ${str(v.prepare.hint_s)}`,
        `hint_k = ${str(v.prepare.hint_k)}`,
        `arbiters = [${v.prepare.arbiters.map(str).join(", ")}]`,
        `verified = "1"`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `s_other = ${str(v.prepare.cp_s)}`,
        `pair_secret = ${str(v.prepare.pair_secret)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.prepare.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `rep_siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `rep_indices = [${v.prepare.indices.join(", ")}]`,
        `source_salt = ${str(modP(BigInt(v.side.source_salt)))}`,
        `note_amount = ${str(v.side.note_amount)}`,
        `note_siblings = [${v.side.note_siblings.map(str).join(", ")}]`,
        `note_indices = [${v.side.note_indices.join(", ")}]`,
      ]),
  },
  {
    // An open account's side of the same deal (2026-10-01): `verified = 0`, no bond — the note half masked.
    name: "prepare_side_open",
    crate: "prepare_side",
    pubs: 21,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.open.deal_subject)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        `token = ${str(v.prepare.token)}`,
        `principal = ${str(v.prepare.principal)}`,
        `decimals = ${str(v.prepare.decimals)}`,
        `rep_root = ${str(v.open.root)}`,
        `new_leaf = ${str(v.open.new_leaf)}`,
        `nullifier = ${str(v.open.null_rep)}`,
        `pair_tag = ${str(v.open.pair_tag)}`,
        `lock_commit = "0"`,
        `lock_amount = "0"`,
        `change_note = "0"`,
        `null_bond_out = "0"`,
        `bond_root = "0"`,
        `registry_id = ${str(v.prepare.registry_id)}`,
        `hint_s = ${str(v.open.hint_s)}`,
        `hint_k = ${str(v.open.hint_k)}`,
        `arbiters = [${v.prepare.arbiters.map(str).join(", ")}]`,
        `verified = "0"`,
        `sk_id = ${str(v.open.sk_id)}`,
        `s_other = ${str(v.open.cp_s)}`,
        `pair_secret = ${str(v.prepare.pair_secret)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.open.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `rep_siblings = [${v.open.siblings.map(str).join(", ")}]`,
        `rep_indices = [${v.open.indices.join(", ")}]`,
        `source_salt = "0"`,
        `note_amount = "0"`,
        `note_siblings = [${Array(20).fill(str(0n)).join(", ")}]`,
        `note_indices = [${Array(20).fill(0).join(", ")}]`,
      ]),
  },
  {
    // A human vouching for the Provider across from a pool (Anexo R, 2026-09-29): the prepare account
    // stands in for the Controller, forming the very pair tag `prepare_side` names for its counterparty.
    // Verified by the same shared `BundleVerifier`, behind `verifyVouch`.
    name: "vouch",
    contract: "VouchVerifier",
    pubs: 11,
    proverToml: (v) =>
      toml([
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        `rep_root = ${str(v.prepare.root)}`,
        `pair_tag = ${str(v.prepare.pair_tag)}`,
        `registry_id = ${str(v.prepare.registry_id)}`,
        `arbiters = [${v.prepare.arbiters.map(str).join(", ")}]`,
        `verified = "1"`,
        // The operator proof of the pool's side (Anexo R, 2026-10-05): this account is the sample pool's
        // Controller, and the counterparty's name in that pool's memory.
        `pool_id = ${str(v.prepare.pool_id)}`,
        `operator_tag = ${str(v.prepare.operator_tag)}`,
        `cp_tag = ${str(v.prepare.pool_cp_tag)}`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `s_other = ${str(v.prepare.cp_s)}`,
        `pair_secret = ${str(v.prepare.pair_secret)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `version = "0"`,
        `cp_root = ${str(v.prepare.cp_root)}`,
        `epoch = "0"`,
        `epoch_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `indices = [${v.prepare.indices.join(", ")}]`,
      ]),
  },
  // ------------------------------------------------------------- V3: the vault circuits
  {
    name: "deposit",
    contract: "DepositVerifier",
    pubs: 3,
    proverToml: (v) =>
      toml([
        `token = ${str(v.deposit.token)}`,
        `amount = ${str(v.deposit.amount)}`,
        `note = ${str(v.deposit.note)}`,
        `sk_id = ${str(v.deposit.sk_id)}`,
        `index = ${str(v.deposit.index)}`,
      ]),
  },
  {
    // Merged into `prepare_side` (§E.3.15.4, 2026-09-23): the statement still has a circuit of its
    // own, and its tests still pin it, but nothing verifies it on chain any more.
    name: "prepare_bond",
    offchain: true,
    pubs: 8,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.bond.deal_subject)}`,
        `deal_id = ${str(modP(BigInt(v.bond.deal_id)))}`,
        `token = ${str(v.bond.token)}`,
        `lock_amount = ${str(v.bond.lock_amount)}`,
        `lock_commit = ${str(v.bond.lock_commit)}`,
        `change_note = ${str(v.bond.change_note)}`,
        `nullifier = ${str(v.bond.null_bond)}`,
        `bond_root = ${str(v.bond.root)}`,
        `sk_id = ${str(v.bond.sk_id)}`,
        `source_salt = ${str(modP(BigInt(v.bond.source_salt)))}`,
        `note_amount = ${str(v.bond.note_amount)}`,
        `siblings = [${v.bond.siblings.map(str).join(", ")}]`,
        `indices = [${v.bond.indices.join(", ")}]`,
      ]),
  },
  {
    name: "claim",
    contract: "ClaimVerifier",
    pubs: 11,
    proverToml: (v) =>
      toml([
        `deal_id = ${str(modP(BigInt(v.claim.deal_id)))}`,
        `subject = ${str(v.claim.deal_subject)}`,
        `new_leaf = ${str(v.claim.new_leaf)}`,
        `nullifier = ${str(v.claim.null_rep)}`,
        `kind = ${str(v.claim.kind)}`,
        `token = ${str(v.claim.token)}`,
        `principal = ${str(v.claim.principal)}`,
        `rep_root = ${str(v.claim.root)}`,
        `pair_tag = ${str(v.claim.pair_tag)}`,
        `epoch = ${str(v.claim.claim_epoch)}`,
        `credit = ${str(v.claim.credit)}`,
        `sk_id = ${str(v.claim.sk_id)}`,
        `count = ${str(v.claim.count)}`,
        `volume = ${str(v.claim.volume)}`,
        `penalty = ${str(v.claim.penalty)}`,
        `in_flight = ${str(v.claim.in_flight)}`,
        `leaf_token = ${str(v.claim.leaf_token)}`,
        `version = ${str(v.claim.version)}`,
        `cp_root = ${str(v.claim.cp_root)}`,
        `leaf_epoch = ${str(v.claim.epoch)}`,
        `leaf_credits = ${str(v.claim.epoch_credits)}`,
        `rec_count = ${str(v.claim.rec_count)}`,
        `rec_volume = ${str(v.claim.rec_volume)}`,
        `verified = ${str(v.claim.verified)}`,
        // The pinned sample credits: a fresh counterparty, so its slot reads zero.
        `s_other = ${str(v.claim.cp_s)}`,
        `pair_secret = ${str(v.claim.pair_secret)}`,
        `slot = "0"`,
        `cp_siblings = [${v.claim.cp_siblings.map(str).join(", ")}]`,
        `siblings = [${v.claim.siblings.map(str).join(", ")}]`,
        `indices = [${v.claim.indices.join(", ")}]`,
      ]),
  },
  {
    // The open account's claim (2026-10-01): Peaceful under `credit = 0` — the record takes the deal, the
    // credit does not.
    name: "claim_open",
    crate: "claim",
    pubs: 11,
    proverToml: (v) =>
      toml([
        `deal_id = ${str(modP(BigInt(v.claim.deal_id)))}`,
        `subject = ${str(v.open.deal_subject)}`,
        `new_leaf = ${str(v.open.claim_new_leaf)}`,
        `nullifier = ${str(v.open.claim_null_rep)}`,
        `kind = "0"`,
        `token = ${str(v.claim.token)}`,
        `principal = ${str(v.claim.principal)}`,
        `rep_root = ${str(v.open.claim_root)}`,
        `pair_tag = ${str(v.open.pair_tag)}`,
        `epoch = ${str(v.claim.claim_epoch)}`,
        `credit = "0"`,
        `sk_id = ${str(v.open.sk_id)}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = ${str(v.claim.principal)}`,
        `leaf_token = ${str(v.claim.token)}`,
        `version = "1"`,
        `cp_root = ${str(v.open.cp_root)}`,
        `leaf_epoch = "0"`,
        `leaf_credits = "0"`,
        `rec_count = "0"`,
        `rec_volume = "0"`,
        `verified = "0"`,
        `s_other = ${str(v.open.cp_s)}`,
        `pair_secret = ${str(v.prepare.pair_secret)}`,
        `slot = "0"`,
        `cp_siblings = [${v.open.cp_siblings.map(str).join(", ")}]`,
        `siblings = [${v.open.claim_siblings.map(str).join(", ")}]`,
        `indices = [${v.open.claim_indices.join(", ")}]`,
      ]),
  },
  {
    name: "reabsorb",
    contract: "ReabsorbVerifier",
    pubs: 8,
    proverToml: (v) =>
      toml([
        `deal_id = ${str(modP(BigInt(v.reabsorb.deal_id)))}`,
        `subject = ${str(v.reabsorb.deal_subject)}`,
        `token = ${str(v.reabsorb.token)}`,
        `amount = ${str(v.reabsorb.amount)}`,
        `kept = ${str(v.reabsorb.kept)}`,
        `lock_commit = ${str(v.reabsorb.lock_commit)}`,
        `new_note = ${str(v.reabsorb.new_note)}`,
        `nullifier = ${str(v.reabsorb.null_bond)}`,
        `sk_id = ${str(v.reabsorb.sk_id)}`,
      ]),
  },
  {
    // The same lock after a court took its share (Anexo R, 2026-10-05): the parties agreed while the court
    // was open, so 15% of the lock went to the panel and the note mints the 85% that is left.
    name: "reabsorb_cut",
    crate: "reabsorb",
    pubs: 8,
    proverToml: (v) =>
      toml([
        `deal_id = ${str(modP(BigInt(v.reabsorb.deal_id)))}`,
        `subject = ${str(v.reabsorb.deal_subject)}`,
        `token = ${str(v.reabsorb.token)}`,
        `amount = ${str(v.reabsorb.amount)}`,
        `kept = ${str(v.reabsorb.cut_kept)}`,
        `lock_commit = ${str(v.reabsorb.lock_commit)}`,
        `new_note = ${str(v.reabsorb.cut_new_note)}`,
        `nullifier = ${str(v.reabsorb.null_bond)}`,
        `sk_id = ${str(v.reabsorb.sk_id)}`,
      ]),
  },
  {
    name: "withdraw",
    contract: "WithdrawVerifier",
    pubs: 6,
    proverToml: (v) =>
      toml([
        `token = ${str(v.withdraw.token)}`,
        `dest = ${str(v.withdraw.dest)}`,
        `amount = ${str(v.withdraw.amount)}`,
        `change_note = ${str(v.withdraw.change_note)}`,
        `nullifier = ${str(v.withdraw.null_bond)}`,
        `bond_root = ${str(v.withdraw.root)}`,
        `sk_id = ${str(v.withdraw.sk_id)}`,
        `source_salt = ${str(modP(BigInt(v.withdraw.source_salt)))}`,
        `note_amount = ${str(v.withdraw.note_amount)}`,
        `siblings = [${v.withdraw.siblings.map(str).join(", ")}]`,
        `indices = [${v.withdraw.indices.join(", ")}]`,
      ]),
  },
  // ------------------------------------------------------------- F4: the disclosure circuits (off-chain)
  {
    name: "attest_base",
    offchain: true,
    pubs: 10,
    proverToml: (v) =>
      toml([
        `handle_commit = ${str(v.attest.handle_commit)}`,
        `tier = ${str(v.attest.tier)}`,
        `count = ${str(v.attest.count_claimed)}`,
        `volume_band = ${str(v.attest.volume_band)}`,
        `penalty_band = ${str(v.attest.penalty_band)}`,
        `expiry = ${str(v.attest.expiry)}`,
        `token = ${str(v.attest.token)}`,
        `decimals = ${str(v.attest.decimals)}`,
        `rep_root = ${str(v.attest.root)}`,
        `verified = ${str(v.attest.verified)}`,
        `sk_id = ${str(v.attest.sk_id)}`,
        `handle_salt = ${str(modP(BigInt(v.attest.handle_salt)))}`,
        `count_actual = ${str(v.attest.count)}`,
        `volume = ${str(v.attest.volume)}`,
        `penalty_actual = ${str(v.attest.penalty)}`,
        `in_flight = ${str(v.attest.in_flight)}`,
        `leaf_token = ${str(v.attest.leaf_token)}`,
        `version = ${str(v.attest.version)}`,
        `cp_root = ${str(v.attest.cp_root)}`,
        `epoch = ${str(v.attest.epoch)}`,
        `epoch_credits = ${str(v.attest.epoch_credits)}`,
        `rec_count = ${str(v.attest.rec_count)}`,
        `rec_volume = ${str(v.attest.rec_volume)}`,
        `siblings = [${v.attest.siblings.map(str).join(", ")}]`,
        `indices = [${v.attest.indices.join(", ")}]`,
      ]),
  },
  {
    name: "reveal_advanced",
    offchain: true,
    pubs: 8,
    proverToml: (v) =>
      toml([
        `handle_commit = ${str(v.reveal.handle_commit)}`,
        `fields_mask = ${str(v.reveal.fields_mask)}`,
        `out_count = ${str(v.reveal.out_count)}`,
        `out_volume = ${str(v.reveal.out_volume)}`,
        `out_penalty = ${str(v.reveal.out_penalty)}`,
        `requester = ${str(v.reveal.requester)}`,
        `token = ${str(v.reveal.token)}`,
        `rep_root = ${str(v.reveal.root)}`,
        `sk_id = ${str(v.reveal.sk_id)}`,
        `handle_salt = ${str(modP(BigInt(v.reveal.handle_salt)))}`,
        `count = ${str(v.reveal.count)}`,
        `volume = ${str(v.reveal.volume)}`,
        `penalty = ${str(v.reveal.penalty)}`,
        `in_flight = ${str(v.reveal.in_flight)}`,
        `leaf_token = ${str(v.reveal.leaf_token)}`,
        `version = ${str(v.reveal.version)}`,
        `cp_root = ${str(v.reveal.cp_root)}`,
        `epoch = ${str(v.reveal.epoch)}`,
        `epoch_credits = ${str(v.reveal.epoch_credits)}`,
        `rec_count = ${str(v.reveal.rec_count)}`,
        `rec_volume = ${str(v.reveal.rec_volume)}`,
        `verified = ${str(v.reveal.verified)}`,
        `siblings = [${v.reveal.siblings.map(str).join(", ")}]`,
        `indices = [${v.reveal.indices.join(", ")}]`,
      ]),
  },
];

// ---------------------------------------------------------------- shell + toml helpers

function sh(cwd: string, command: string): string {
  const env = { ...process.env, PATH: `${BIN}:${process.env.PATH ?? ""}` };
  return execSync(command, { cwd, env, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

function toml(lines: string[]): string {
  return lines.join("\n") + "\n";
}

function str(x: bigint | string): string {
  return `"${x}"`;
}

function hex(bytes: Buffer): string {
  // Bare hex, no "0x": forge's vm.parseJsonBytes prepends its own prefix — a prefixed
  // value double-prefixes and fails to parse (the same quirk the pilot hit).
  return bytes.toString("hex");
}

// ---------------------------------------------------------------- main

function main() {
  const vectors = JSON.parse(readFileSync(join(REPO, "test/fixtures/vectors.json"), "utf8")) as Vectors;

  const only = process.argv.slice(2);
  const unknown = only.filter((n) => !CIRCUIT_LIST.some((c) => c.name === n));
  if (unknown.length > 0) throw new Error(`unknown circuit(s): ${unknown.join(", ")}`);
  const selected = CIRCUIT_LIST.filter((c) => only.length === 0 || only.includes(c.name));

  console.log("compiling circuits...");
  sh(CIRCUITS, "nargo compile");
  for (const circuit of selected) {
    console.log(`=== ${circuit.name} ===`);
    // A variant proves its package under its own Prover file, so the package's own Prover.toml stays the
    // main sample's; the witness is named after the fixture either way.
    const pkg = circuit.crate ?? circuit.name;
    const prover = circuit.crate ? `Prover_${circuit.name}` : "Prover";
    writeFileSync(join(CIRCUITS, "crates", pkg, `${prover}.toml`), circuit.proverToml(vectors));
    sh(join(CIRCUITS, "crates", pkg), `nargo execute -p ${prover} ${circuit.name}`);

    const vkDir = join(CIRCUITS, "target", `${pkg}_vk`);
    const proofDir = join(CIRCUITS, "target", `${circuit.name}_proof`);
    const bytecode = join(CIRCUITS, "target", `${pkg}.json`);
    const witness = join(CIRCUITS, "target", `${circuit.name}.gz`);
    sh(CIRCUITS, `bb write_vk -b ${bytecode} -o ${vkDir} -t evm`);
    sh(CIRCUITS, `bb prove -b ${bytecode} -w ${witness} -k ${join(vkDir, "vk")} -o ${proofDir} -t evm`);
    const verified = sh(
      CIRCUITS,
      `bb verify -k ${join(vkDir, "vk")} -p ${join(proofDir, "proof")} -i ${join(proofDir, "public_inputs")} -t evm 2>&1`,
    );
    if (!verified.includes("Proof verified successfully")) {
      throw new Error(`${circuit.name}: bb verify did not pass`);
    }
    console.log(`  bb verify: ok`);

    // The proof fixture: exactly the blob an adapter splits (proof || public inputs).
    const proof = readFileSync(join(proofDir, "proof"));
    const pubs = readFileSync(join(proofDir, "public_inputs"));
    const expectedPubs = circuit.pubs * 32;
    if (pubs.length !== expectedPubs) {
      throw new Error(`${circuit.name}: expected ${expectedPubs} public input bytes, got ${pubs.length}`);
    }
    const fixtureDir = join(REPO, "test/fixtures/proofs");
    mkdirSync(fixtureDir, { recursive: true });
    const fixture = { proof_with_public_inputs: hex(Buffer.concat([proof, pubs])) };
    writeFileSync(
      join(fixtureDir, `${circuit.name}.json`),
      JSON.stringify(fixture, null, 2) + "\n",
    );
    console.log(`  proof fixture: ${pubs.length} bytes of public inputs (== ${circuit.pubs} Field elements)`);
    if (circuit.crate) continue; // a variant: the package's verifier / VK are its main row's

    if (circuit.offchain || !circuit.contract) {
      // The off-chain circuits (F4): the consumer verifies with bb (or bb.js later), so
      // the verification KEY is the fixture — no EVM verifier, no initcode. Committed as
      // hex exactly like the adapters' initcode: the consumer pins it, nothing deploys it.
      const vkFixtureDir = join(REPO, "test/fixtures/vks");
      mkdirSync(vkFixtureDir, { recursive: true });
      writeFileSync(
        join(vkFixtureDir, `${circuit.name}.json`),
        JSON.stringify({ vk: hex(readFileSync(join(vkDir, "vk"))) }, null, 2) + "\n",
      );
      console.log(`  vk fixture: test/fixtures/vks/${circuit.name}.json`);
      continue;
    }

    // The verifier contract: bb writes `HonkVerifier`/`IVerifier`; two circuits cannot both
    // declare those names in one solc run, so each file is renamed to its circuit's contract.
    const verifierPath = join(REPO, "verifiers", "src", `${circuit.contract}.sol`);
    sh(
      CIRCUITS,
      `bb write_solidity_verifier -k ${join(vkDir, "vk")} -o ${verifierPath} -t evm --optimized`,
    );
    renameVerifierContracts(verifierPath, circuit.contract);
    console.log(`  verifier: verifiers/src/${circuit.contract}.sol`);
  }

  // Initcode fixtures from the verifiers subproject (its own foundry.toml compiles the
  // generated contracts with via_ir off — see verifiers/foundry.toml).
  console.log("building the verifiers project...");
  sh(join(REPO, "verifiers"), "forge build");
  const initcodeDir = join(REPO, "test/fixtures/verifiers");
  mkdirSync(initcodeDir, { recursive: true });
  for (const circuit of selected) {
    if (circuit.offchain || !circuit.contract || circuit.crate) continue; // off-chain or a variant: no initcode
    const artifact = join(
      REPO,
      "verifiers",
      "out",
      `${circuit.contract}.sol`,
      `${circuit.contract}.json`,
    );
    if (!existsSync(artifact)) {
      throw new Error(`the verifiers project did not produce ${artifact}`);
    }
    const object = JSON.parse(readFileSync(artifact, "utf8")).bytecode.object;
    if (typeof object !== "string" || object.length === 0) {
      throw new Error(`${circuit.contract}: no initcode in artifact`);
    }
    writeFileSync(
      join(initcodeDir, `${circuit.name}.json`),
      JSON.stringify({ initcode: object }, null, 2) + "\n" // artifact object is bare hex,
    );
    console.log(`  initcode: test/fixtures/verifiers/${circuit.name}.json`);
  }
  console.log("done.");
}

/** Rename the generated `HonkVerifier`/`IVerifier` to this circuit's own names (in place). */
function renameVerifierContracts(path: string, contract: string): void {
  const generated = readFileSync(path, "utf8");
  const renamed = generated
    .replaceAll("HonkVerifier", contract)
    .replaceAll("IVerifier", `I${contract}`);
  if (renamed === generated) {
    throw new Error(`${path}: no contract names found to rename`);
  }
  writeFileSync(path, renamed);
}

main();
