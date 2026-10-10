// Recovering a private VAULT from its secret and the chain — the notes half of what
// `account.ts` does for the reputation leaf, and the reason the note salts became derived
// (§E.3.15.6, 2026-09-23).
//
// A note holds tokens and its salt is what spends it (`nullBond` is taken over the salt), so a
// salt that only lived in a client's local state was money that died with a laptop. The rule the
// circuits now enforce: A NOTE'S SALT DERIVES FROM WHATEVER THE NOTE CAME FROM.
//
//   deposit   no parent      seed = a small per-account index (the circuit binds it under 2^32)
//   split     prepare_bond   the change's seed = the nullifier the split published
//   withdraw  withdraw       the change's seed = the nullifier the withdraw published
//   reabsorb  reabsorb       the merged note's seed = the released lock's nullifier
//   lock      prepare_bond   the earmark's salt = derived from the DEAL (one lock per deal)
//
// That closes the salts. The AMOUNTS close too, and by the same accident of design: every
// transition publishes its own delta — a deposit publishes `(token, amount)`, a withdraw its
// `amount`, a split its `lockAmount`, a reabsorb the record's `amount`. So a child's amount is its
// parent's minus something the chain states, and the walk bottoms out at deposits, which are
// public in full. Salts derived + amounts derivable = the vault is reconstructible from `sk_id`
// and the chain, with nothing kept on the side.
//
// This module is the walk, as pure functions over public facts. It reads no chain itself: feed it
// what an indexer saw (`indexer.ts` rebuilds the notes tree exactly as it rebuilds the accounts
// one — same contract shape, depth 20), match each returned commitment against the tree, and the
// ones that are present and unspent are the vault's live balance.

import { lockCommit, lockSalt, noteBond, noteSalt, nullBond } from "./commitments.ts";

/** A note as its owner holds it: the secrets that spend it plus the commitment in the tree. */
export type Note = {
  token: bigint;
  amount: bigint;
  salt: bigint;
  /** `noteBond(sk_id, token, amount, salt)` — the leaf the notes tree carries. */
  commitment: bigint;
  /** What spending it will burn. Already spent means this note moved on. */
  nullifier: bigint;
};

/** A lock as the vault stored it: the earmark a reserve proved openable. */
export type Lock = {
  dealId: bigint;
  token: bigint;
  amount: bigint;
  salt: bigint;
  /** `lockCommit(sk_id, dealId, amount, salt)` — the record the contract holds. */
  commitment: bigint;
  /** What reabsorbing it will burn. */
  nullifier: bigint;
};

async function note(skId: bigint, token: bigint, amount: bigint, salt: bigint): Promise<Note> {
  return {
    token,
    amount,
    salt,
    commitment: await noteBond(skId, token, amount, salt),
    nullifier: await nullBond(skId, salt),
  };
}

/** The note a deposit of `(token, amount)` at the account's `index`-th deposit creates. */
export async function depositNote(skId: bigint, token: bigint, amount: bigint, index: bigint): Promise<Note> {
  return note(skId, token, amount, await noteSalt(skId, index));
}

/**
 * The deposit's own recovery step: a deposit event states `(token, amount, note)` in the clear, so
 * the owner finds theirs by trying indices until the commitment matches.
 *
 * `gap` is the client's business, not the protocol's — the circuit only bounds the index under
 * 2^32. A client that always allocates the next index needs no gap at all; one that abandons
 * indices (an unsent transaction) needs a window past the abandoned ones, exactly like BIP-44.
 */
export async function findDeposit(
  skId: bigint,
  token: bigint,
  amount: bigint,
  commitment: bigint,
  gap = 20,
): Promise<Note | null> {
  for (let i = 0n; i < BigInt(gap); i++) {
    const candidate = await depositNote(skId, token, amount, i);
    if (candidate.commitment === commitment) return candidate;
  }
  return null;
}

/**
 * The split (`prepare_bond`): a note becomes an earmark for a deal plus the change. Both children
 * derive — the lock from the deal it belongs to, the change from the burn of its parent — so a
 * split is re-walkable from the parent and the public `lockAmount` alone.
 *
 * The change is `null` when the lock takes the note whole (nothing lives on).
 */
export async function split(
  skId: bigint,
  parent: Note,
  dealId: bigint,
  lockAmount: bigint,
): Promise<{ lock: Lock; change: Note | null }> {
  if (lockAmount < 1n || lockAmount > parent.amount) throw new Error("lock over the note");
  const lSalt = await lockSalt(skId, dealId);
  const lock: Lock = {
    dealId,
    token: parent.token,
    amount: lockAmount,
    salt: lSalt,
    commitment: await lockCommit(skId, dealId, lockAmount, lSalt),
    nullifier: await nullBond(skId, lSalt),
  };
  const changeAmount = parent.amount - lockAmount;
  const change = await note(skId, parent.token, changeAmount, await noteSalt(skId, parent.nullifier));
  return { lock, change: changeAmount === 0n ? null : change };
}

/** The withdraw: `amount` leaves for a dest, the remainder lives on as change (`null` when the
 *  note is consumed whole — §E.3.15.6's masked branch, where the circuit publishes `changeNote == 0`). */
export async function withdraw(skId: bigint, parent: Note, amount: bigint): Promise<Note | null> {
  if (amount < 1n || amount > parent.amount) throw new Error("withdraw over the note");
  if (amount === parent.amount) return null;
  return note(skId, parent.token, parent.amount - amount, await noteSalt(skId, parent.nullifier));
}

/** The reabsorb: a released lock merges back into a note seeded by the lock's own burn — whole, or `kept` of
 *  it when a court took its share (Anexo R, 2026-10-05: the parties agreed while the court was open). */
export async function reabsorb(skId: bigint, lock: Lock, kept: bigint = lock.amount): Promise<Note> {
  if (kept < 1n || kept > lock.amount) throw new Error("kept over the lock");
  return note(skId, lock.token, kept, await noteSalt(skId, lock.nullifier));
}
