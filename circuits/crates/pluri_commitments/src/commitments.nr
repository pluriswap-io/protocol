// The canonical commitments of §E.3.15.3 (as amended by the canonical-encoding decision):
// one builder per commitment the circuits prove about. Identical to the JS twin
// (circuits/js/lib/commitments.ts) and the Solidity twin
// (src/packages/libraries/PrivacyCommitments.sol); parity pinned by vectors.nr (test/fixtures/vectors.json).
//
// Chaining rule (the §E.3.15.3 amendment): a multi-field commitment chains PoseidonT3 in a
// pinned left fold over the field order of the spec — h0 = f0, hi = PoseidonT3(h(i-1), fi).
// Nullifier tags are pinned field constants inside this library's namespace.
use crate::poseidon2::permutation as t2_perm;
use crate::poseidon3::permutation as t3_perm;
use crate::vectors;

pub global TAG_REP: Field = 1;
pub global TAG_BOND: Field = 2;
pub global TAG_HANDLE: Field = 3;
pub global TAG_LEAF: Field = 4;
pub global TAG_NOTE: Field = 5;
pub global TAG_LOCK: Field = 6;
pub global TAG_PAIR: Field = 7;
pub global TAG_CP: Field = 8;
pub global TAG_FIAT: Field = 9;
pub global TAG_HINT: Field = 10;
pub global TAG_OPERATOR: Field = 11;
pub global TAG_POOL_CP: Field = 12;
pub global TAG_IDENTITY: Field = 13;

/// Depth of an account's own COUNTERPARTY tree (§E.3.14.7 anti-farming). 32 levels of sparse slots,
/// addressed by `cp_path`: with a few hundred counterparties the odds of two landing on the same
/// slot are around 10^-4, and a collision only ever DENIES credit — the safe direction.
pub global CP_DEPTH: u32 = 32;

/// PoseidonT2 (one input, capacity 0): `S = Poseidon(sk_id)` — the account.
pub fn poseidon_t2(x: Field) -> Field {
    t2_perm([0, x])[0]
}

/// PoseidonT3 (two inputs, capacity 0): tree nodes, `hn`, `dealSubject`, the chain primitive.
pub fn poseidon_t3(a: Field, b: Field) -> Field {
    t3_perm([0, a, b])[0]
}

/// The pinned left fold of the multi-field commitments.
pub fn chain<let N: u32>(fields: [Field; N]) -> Field {
    let mut h = fields[0];
    for i in 1..N {
        h = poseidon_t3(h, fields[i]);
    }
    h
}

/// `S = Poseidon(sk_id)` — the account; lives inside leafRep, never on-chain in the clear.
pub fn account_commitment(sk_id: Field) -> Field {
    poseidon_t2(sk_id)
}

/// `identityCommitment = Poseidon("identity", hsk)` — what HumanityRegistry enrolls next to the anchor.
/// Tagged so it is not `S`: with `hsk == sk_id` an untagged `Poseidon(hsk)` IS the account commitment, which
/// every counterparty learns, and the public enrollment would link the account to its anchor wallet.
pub fn identity_commitment(hsk: Field) -> Field {
    poseidon_t3(TAG_IDENTITY, hsk)
}

/// `hn = Poseidon(anchor, registryId)` — the humanity nullifier; anchor = Passport-live address.
pub fn hn(anchor: Field, registry_id: Field) -> Field {
    poseidon_t3(anchor, registry_id)
}

/// `dealSubject = Poseidon(sk_id, dealId)` — the per-deal pseudonym; all the kernel ever sees.
pub fn deal_subject(sk_id: Field, deal_id: Field) -> Field {
    poseidon_t3(sk_id, deal_id)
}

/// `nullRep = Poseidon(sk_id, "rep", version)` — one use per account version.
pub fn null_rep(sk_id: Field, version: Field) -> Field {
    chain([sk_id, TAG_REP, version])
}

/// `leafSalt = Poseidon(sk_id, "leaf", version)` — the account leaf's salt, DERIVED.
///
/// It used to be whatever the prover picked, which made an account unrecoverable from its secret:
/// rebuilding your leaf means reproducing its salt, and without a derivation the salt only lived in
/// the client's local state. Deriving it costs nothing in privacy — the leaf already hides behind
/// `S = Poseidon(sk_id)`, and whoever can recompute this salt already holds `sk_id` — and it buys
/// the property that `sk_id` alone is enough to recover an account.
///
/// The circuits ENFORCE it rather than trusting the prover to follow a convention: a user of a
/// non-conforming client would not discover the problem until the day they needed to recover, and
/// that is the one day it cannot be fixed.
pub fn leaf_salt(sk_id: Field, version: Field) -> Field {
    chain([sk_id, TAG_LEAF, version])
}

/// `pairId = Poseidon("pair", S_a + S_b, S_a · S_b)` — the name two accounts share, computed
/// COMMUTATIVELY without ordering them (this nargo has no relational operators on Field, so sorting
/// two field elements is not available; the symmetric polynomials are, and the unordered pair is
/// uniquely determined by its sum and its product).
///
/// It is what lets the anti-farming rule of §E.3.14.7 exist at all, and its soundness is a small
/// pleasure: each side proves this with its OWN `S` bound to its own leaf and the other's as a
/// private witness. For the two proofs to land on the same value the multisets must match — and
/// since `S_a != S_b`, the only solution is that each used the other's true `S`. A farmer running
/// both sides cannot mint a fresh pair name per round without breaking Poseidon; the honest pair
/// is forced.
pub fn pair_id(s_a: Field, s_b: Field) -> Field {
    chain([TAG_PAIR, s_a + s_b, s_a * s_b])
}

/// `pairTag = Poseidon(pairId, dealId, k)` — what the two sides of ONE activation publish so the
/// module can check they named the same counterparty.
///
/// Blinded by the deal on purpose. A bare `pairId` would be identical across every deal between the
/// same two accounts, which publishes the trading graph — precisely what §E.3.15.8 keeps hidden. Tagged
/// by `dealId` it is fresh every time, so it proves agreement WITHIN a deal and says nothing across
/// deals. The cross-deal memory lives privately instead, inside each account's own counterparty tree.
///
/// And blinded by `k`, a secret the two sides pick together for this deal (Anexo R, 2026-09-29). The
/// deal alone was not enough: the sides exchange their `S` to prove the pair, so whoever collected the
/// `S` of several counterparties — a market maker, a relayer — could test every pair of them against
/// every deal's tag and rebuild who traded with whom. Without `k` they cannot.
pub fn pair_tag(s_a: Field, s_b: Field, deal_id: Field, k: Field) -> Field {
    chain([pair_id(s_a, s_b), deal_id, k])
}

/// The one-time pad an account masks what it must remember about a deal with: `Poseidon(sk_id,
/// "hint", dealId, which)`. The activation publishes the counterparty's `S` (which = 1) and the pair
/// secret `k` (which = 2) under it, so an account rebuilds its counterparty tree from `sk_id` and the
/// chain — nobody else can open them, and each deal's pad is different.
pub fn hint_key(sk_id: Field, deal_id: Field, which: Field) -> Field {
    chain([sk_id, TAG_HINT, deal_id, which])
}

/// The slot a counterparty occupies in an account's counterparty tree: the low `CP_DEPTH` bits of
/// `Poseidon("cp", S_other)`, little-endian, one bit per level.
///
/// Derived rather than chosen, for the same reason every salt in this protocol is: the claim must not
/// be free to point its non-membership proof at whatever empty slot it likes. The truncation is the
/// point — an address space of 2^32 slots for a few hundred entries — and the cast keeps the low bits
/// (pinned by `field_to_u32_truncates`).
pub fn cp_path(s_other: Field) -> [u8; CP_DEPTH] {
    let h = poseidon_t3(TAG_CP, s_other);
    let mut rest: u32 = h as u32;
    let mut bits: [u8; CP_DEPTH] = [0; CP_DEPTH];
    for i in 0..CP_DEPTH {
        bits[i] = (rest & 1) as u8;
        rest = rest >> 1;
    }
    bits
}

/// `noteSalt = Poseidon(sk_id, "note", seed)` — a vault note's salt, DERIVED, for the same reason
/// the account leaf's is (`leaf_salt`) and with more at stake: a note holds TOKENS, and its salt is
/// what spends it (`null_bond` is taken over the salt). A salt that only lives in a client's local
/// state is money that dies with a laptop.
///
/// Two seed families, one rule — a note's salt derives from whatever the note came from:
///   * a DEPOSIT has no parent, so the seed is a small per-account index (the deposit circuit binds
///     it under 2^32). Recovery walks the index space against the public deposit events.
///   * every other note is change: the seed is the NULLIFIER of the note or lock it came out of,
///     which the spending transaction publishes. No counter, no gap, no ambiguity — the recovery
///     walk follows the same edges the chain already shows.
///
/// The two families cannot collide in practice: a nullifier is a Poseidon output, uniform over the
/// field, so landing inside the 2^32 index window has probability ~2^-222.
///
/// Recovery works because every amount is public somewhere: a deposit publishes `(token, amount)`,
/// a withdraw its `amount`, a bond split its `lockAmount`, a reabsorb the record's `amount`. So a
/// child's amount is its parent's minus something the chain states, and the walk bottoms out at
/// deposits, which are public in full. Salts derived + amounts derivable = the vault is
/// reconstructible from `sk_id` and the chain, with nothing kept on the side.
pub fn note_salt(sk_id: Field, seed: Field) -> Field {
    chain([sk_id, TAG_NOTE, seed])
}

/// `lockSalt = Poseidon(sk_id, "lock", dealId)` — the earmark's salt, DERIVED from the deal it
/// belongs to. One lock per deal per subject (the kernel reserves once), so the deal id is the only
/// index it needs — and `reabsorb` gets its whole witness back from public data: the record names
/// the deal, the deal derives the salt.
pub fn lock_salt(sk_id: Field, deal_id: Field) -> Field {
    chain([sk_id, TAG_LOCK, deal_id])
}

/// `nullBond = Poseidon(sk_id, "bond", noteSalt)` — one use per spent note.
pub fn null_bond(sk_id: Field, note_salt: Field) -> Field {
    chain([sk_id, TAG_BOND, note_salt])
}

/// `handleCommit = Poseidon(sk_id, "handle", handleSalt)` — the rotable market pseudonym.
pub fn handle_commit(sk_id: Field, handle_salt: Field) -> Field {
    chain([sk_id, TAG_HANDLE, handle_salt])
}

/// `noteBond = Poseidon(sk_id, token, amount, salt)` — token-specific vault note (F3).
pub fn note_bond(sk_id: Field, token: Field, amount: Field, salt: Field) -> Field {
    chain([sk_id, token, amount, salt])
}

/// `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` — the earmark a reserve proves
/// openable. The fold's first step is exactly `dealSubject`: the lock binds to the deal.
pub fn lock_commit(sk_id: Field, deal_id: Field, lock_amount: Field, salt: Field) -> Field {
    chain([sk_id, deal_id, lock_amount, salt])
}

/// `fiatCommit = Poseidon("fiat", rail, currency, amount, payee, salt)` — the fiat leg of a deal, the
/// one field of `DealTerms` the kernel signs and never reads (§E.3.13).
///
///   rail      which payment network — `keccak("pluri:rail:<name>") mod p`, the pinned rule for ids
///   currency  ISO 4217 numeric code (986 BRL, 32 ARS, 840 USD)
///   amount    in the currency's minor units (ISO 4217 exponent): what the Holder must RECEIVE
///   payee     the Holder's account on that rail, in the rail's canonical encoding — the rail's
///             payment circuit fixes the normalization, so two spellings of one account are one payee
///   salt      uniformly random, chosen by the Holder and handed to the Provider off-chain
///
/// Hidden on purpose: the terms are public forever, the payee is a bank account, and a visible currency
/// would partition the anonymity set of §E.3.15.8 by country. The salt is what makes it hiding — amount
/// and currency are low entropy, and without it a table of plausible trades would open the commitment.
/// Unlike every other salt in this library it is NOT derived: it has to be shared with a counterparty,
/// and deriving it from anything the counterparty may know would hand them the Holder's other deals.
///
/// Tag first, like `pair_id`: there is no secret in the preimage to separate the domain, so the tag does.
/// The fold's width has nothing to do with the rail — a payment circuit proves the payment it saw opens
/// THIS commitment, whatever network carried it.
pub fn fiat_commit(rail: Field, currency: Field, amount: Field, payee: Field, salt: Field) -> Field {
    chain([TAG_FIAT, rail, currency, amount, payee, salt])
}

/// `operatorTag = Poseidon(sk_id, "operator", poolId)` — the operator commitment of a pool's Controller
/// (Anexo R, 2026-10-05: a side is an account plus an operator). The Controller registers it once in the
/// pool; every vouch proves the human behind the deal's Controller is the one who registered it.
///
/// Secret first, like every account-side builder: only the holder of `sk_id` can form it, and the pool id
/// makes two pools' tags of one human unlinkable — the wallet is public as "an operator of this pool",
/// never as "this account".
pub fn operator_tag(sk_id: Field, pool_id: Field) -> Field {
    chain([sk_id, TAG_OPERATOR, pool_id])
}

/// `poolCpTag = Poseidon("pool-cp", S_other, poolId)` — the Provider's name in ONE pool's public
/// counterparty memory (Anexo R, 2026-10-05: a pool climbs the ladder like a peer, credit once per
/// distinct counterparty).
///
/// Tag first, like `pair_id`: the Controller who forms it knows the Provider's `S`, so no secret separates
/// the domain. It is sound because the vouch's `pair_tag` already forces `S_other` to be the Provider's true
/// `S`. It is stable across the pool's deals with that Provider — that is the point, the pool must recognize
/// a repeat — and the pool id keeps it from naming the Provider anywhere else.
pub fn pool_cp_tag(s_other: Field, pool_id: Field) -> Field {
    chain([TAG_POOL_CP, s_other, pool_id])
}

/// `leafRep = Poseidon(S, count, volume, penalty, inFlight, token, salt, version)` — the account leaf.
pub fn leaf_rep(
    s: Field,
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    token: Field,
    salt: Field,
    version: Field,
    // The anti-farming state of §E.3.14.7, added 2026-09-23 while nothing was deployed: a leaf field
    // cannot be added later without leaving every existing leaf unprovable, which is the same
    // migration cliff the derived salts had.
    //
    //   cp_root       the root of THIS account's counterparty tree — who has already vouched for it
    //                 by trading with it. Credit is once per counterparty; this is where that memory
    //                 lives, privately, so the rule costs no linkability.
    //   epoch         the rate window the last credit was taken in
    //   epoch_credits how much of that window is already spent
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
    // The open accounts of 2026-10-01 (an account without a Passport): the PUBLIC RECORD and the flag,
    // added while nothing was deployed, for the same migration-cliff reason as the three above.
    //
    //   rec_count     every completed deal, credited or not — what the listing shows as the account's
    //                 deal count. `count` above is the CREDIT: the deals that buy tier, once per
    //                 counterparty, and only between two verified accounts
    //   rec_volume    the same split for volume: `volume` is credit, this is the record
    //   verified      1 when a proof of humanity stands behind the account (registered with one, or
    //                 upgraded later), 0 for an open account. Bonds and credit need it; the record
    //                 and the penalties do not
    rec_count: Field,
    rec_volume: Field,
    verified: Field,
) -> Field {
    chain(
        [
            s, count, volume, penalty, in_flight, token, salt, version, cp_root, epoch, epoch_credits, rec_count,
            rec_volume, verified,
        ],
    )
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn zero_gate_matches_circom_vector() {
    assert(poseidon_t3(1, 2) == vectors::ZERO_EXPECTED, "poseidon(1,2) != circomlib vector");
}

#[test]
fn high_edge_matches() {
    assert(poseidon_t3(vectors::P2_BIG_A, vectors::P2_BIG_B) == vectors::P2_BIG_EXPECTED);
}

#[test]
fn the_hint_pads_match_and_differ() {
    assert(hint_key(vectors::SK_ID, vectors::DEAL_ID, 1) == vectors::EXPECTED_HINT_KEY_S, "hint key S");
    assert(hint_key(vectors::SK_ID, vectors::DEAL_ID, 2) == vectors::EXPECTED_HINT_KEY_K, "hint key k");
    assert(vectors::EXPECTED_HINT_KEY_S != vectors::EXPECTED_HINT_KEY_K, "two pads, not one");
}

#[test]
fn the_pair_secret_blinds_the_tag() {
    // Same pair, same deal, another secret: another tag. Whoever holds both `S` but not `k` has nothing
    // to test a tag against.
    let a = pair_tag(vectors::PAIR_S_A, vectors::PAIR_S_B, vectors::DEAL_ID, vectors::PAIR_K);
    let b = pair_tag(vectors::PAIR_S_A, vectors::PAIR_S_B, vectors::DEAL_ID, vectors::PAIR_K + 1);
    assert(a != b, "k binds");
}

#[test]
fn builders_match_vectors() {
    let s = account_commitment(vectors::SK_ID);
    assert(s == vectors::EXPECTED_S, "S");
    assert(hn(vectors::ANCHOR, vectors::REGISTRY_ID) == vectors::EXPECTED_HN, "hn");
    assert(identity_commitment(vectors::IDENTITY_HSK) == vectors::EXPECTED_IDENTITY, "identityCommitment");
    // The enrolled commitment is never the account's `S` for the same secret.
    assert(identity_commitment(vectors::IDENTITY_HSK) != account_commitment(vectors::IDENTITY_HSK), "identity is S");
    assert(deal_subject(vectors::SK_ID, vectors::DEAL_ID) == vectors::EXPECTED_DEAL_SUBJECT, "dealSubject");
    assert(null_rep(vectors::SK_ID, vectors::VERSION) == vectors::EXPECTED_NULL_REP, "nullRep");
    assert(null_bond(vectors::SK_ID, vectors::NOTE_SALT) == vectors::EXPECTED_NULL_BOND, "nullBond");
    assert(note_salt(vectors::SK_ID, vectors::NOTE_SALT) == vectors::EXPECTED_NOTE_SALT, "noteSalt");
    assert(lock_salt(vectors::SK_ID, vectors::DEAL_ID) == vectors::EXPECTED_LOCK_SALT, "lockSalt");
    assert(pair_id(vectors::PAIR_S_A, vectors::PAIR_S_B) == vectors::EXPECTED_PAIR_ID, "pairId");
    assert(
        pair_tag(vectors::PAIR_S_A, vectors::PAIR_S_B, vectors::DEAL_ID, vectors::PAIR_K) == vectors::EXPECTED_PAIR_TAG,
        "pairTag",
    );
    assert(handle_commit(vectors::SK_ID, vectors::HANDLE_SALT) == vectors::EXPECTED_HANDLE_COMMIT, "handleCommit");
    assert(note_bond(vectors::SK_ID, vectors::TOKEN_ID, vectors::AMOUNT, vectors::NOTE_SALT) == vectors::EXPECTED_NOTE_BOND, "noteBond");
    assert(lock_commit(vectors::SK_ID, vectors::DEAL_ID, vectors::LOCK_AMOUNT, vectors::LOCK_SALT) == vectors::EXPECTED_LOCK_COMMIT, "lockCommit");
    assert(
        fiat_commit(vectors::FIAT_RAIL, vectors::FIAT_CURRENCY, vectors::FIAT_AMOUNT, vectors::FIAT_PAYEE, vectors::FIAT_SALT)
            == vectors::EXPECTED_FIAT_COMMIT,
        "fiatCommit",
    );
    assert(
        leaf_rep(
            s,
            vectors::COUNT,
            vectors::VOLUME,
            vectors::PENALTY,
            vectors::IN_FLIGHT,
            vectors::TOKEN_ID,
            vectors::LEAF_SALT,
            vectors::VERSION,
            vectors::LEAF_CP_ROOT,
            vectors::LEAF_EPOCH,
            vectors::LEAF_EPOCH_CREDITS,
            vectors::LEAF_REC_COUNT,
            vectors::LEAF_REC_VOLUME,
            vectors::LEAF_VERIFIED,
        ) == vectors::EXPECTED_LEAF_REP,
        "leafRep",
    );
}

#[test]
fn the_pool_builders_match_vectors() {
    assert(
        operator_tag(vectors::SK_ID, vectors::POOL_ID) == vectors::EXPECTED_OPERATOR_TAG,
        "operatorTag",
    );
    assert(
        pool_cp_tag(vectors::PAIR_S_B, vectors::POOL_ID) == vectors::EXPECTED_POOL_CP_TAG,
        "poolCpTag",
    );
}

#[test]
fn the_pool_tags_do_not_cross_pools() {
    // One operator, two pools: two tags nobody can link. One Provider, two pools: the same.
    assert(operator_tag(vectors::SK_ID, vectors::POOL_ID) != operator_tag(vectors::SK_ID, vectors::POOL_ID + 1));
    assert(pool_cp_tag(vectors::PAIR_S_B, vectors::POOL_ID) != pool_cp_tag(vectors::PAIR_S_B, vectors::POOL_ID + 1));
    // And the two roles never name the same value, even over the same field element.
    assert(operator_tag(vectors::PAIR_S_B, vectors::POOL_ID) != pool_cp_tag(vectors::PAIR_S_B, vectors::POOL_ID));
}

#[test]
fn tags_are_distinct() {
    assert((TAG_REP != TAG_BOND) & (TAG_BOND != TAG_HANDLE) & (TAG_REP != TAG_HANDLE));
    assert((TAG_LEAF != TAG_REP) & (TAG_LEAF != TAG_BOND) & (TAG_LEAF != TAG_HANDLE));
    assert((TAG_NOTE != TAG_REP) & (TAG_NOTE != TAG_BOND) & (TAG_NOTE != TAG_HANDLE) & (TAG_NOTE != TAG_LEAF));
    assert(
        (TAG_LOCK != TAG_REP)
            & (TAG_LOCK != TAG_BOND)
            & (TAG_LOCK != TAG_HANDLE)
            & (TAG_LOCK != TAG_LEAF)
            & (TAG_LOCK != TAG_NOTE),
    );
}

#[test]
fn a_salt_is_never_its_own_nullifier() {
    // The domain separation that matters for the derived salts: a note's salt and the nullifier
    // taken OVER that salt are different tags of the same fold, so they cannot collide — which is
    // what lets a child's salt be seeded by its parent's nullifier without the two ever naming the
    // same value.
    let salt = note_salt(vectors::SK_ID, 7);
    assert(salt != null_bond(vectors::SK_ID, 7), "note tag != bond tag");
    assert(note_salt(vectors::SK_ID, salt) != salt, "a salt never seeds itself");
    // And the two seed families of `note_salt` (a small deposit index, a parent nullifier) stay
    // apart because a nullifier is a Poseidon output: nothing forces it, but nothing lands there.
    assert(null_bond(vectors::SK_ID, salt) != 0, "the nullifier is a field element, not an index");
}

#[test]
fn field_to_u32_truncates() {
    // The whole counterparty-path derivation rests on this: casting a big Field down to u32 keeps the
    // LOW 32 bits rather than failing. (The cast-round-trip idiom used everywhere else in this crate
    // only makes sense if that is the behaviour — it asserts the round trip precisely to catch it.)
    let big: Field = 0x1234567800000000 + 0xdeadbeef;
    let low: u32 = big as u32;
    assert(low == 0xdeadbeef, "the low 32 bits survive");
    assert(low as Field != big, "and the high ones are gone");
}

#[test]
fn the_pair_does_not_care_who_asks() {
    // The property the anti-farming rule is built on: `pair_id` is commutative, so the two sides of a
    // deal reach the same name without ever having to agree on an order — which this nargo could not
    // express anyway (no relational operators on Field). The generator pins both orders; here is the
    // function itself saying it.
    assert(
        pair_id(vectors::PAIR_S_A, vectors::PAIR_S_B) == pair_id(vectors::PAIR_S_B, vectors::PAIR_S_A),
        "the pair is unordered",
    );
    assert(vectors::EXPECTED_PAIR_ID == vectors::EXPECTED_PAIR_ID_SWAPPED, "and the twin agrees");
}

#[test]
fn a_counterparty_cannot_choose_its_own_slot() {
    // The slot is a function of the counterparty's account commitment, so a claim cannot aim its
    // non-membership proof at a convenient empty corner of the tree. Different accounts, different
    // paths; the same account, the same path, every time.
    let a = cp_path(vectors::PAIR_S_A);
    let b = cp_path(vectors::PAIR_S_B);
    let a_again = cp_path(vectors::PAIR_S_A);
    let mut same_as_itself = true;
    let mut differs_somewhere = false;
    for i in 0..CP_DEPTH {
        assert(a[i] < 2, "a path is bits");
        same_as_itself = same_as_itself & (a[i] == a_again[i]);
        differs_somewhere = differs_somewhere | (a[i] != b[i]);
    }
    assert(same_as_itself, "derived, not chosen");
    assert(differs_somewhere, "two accounts do not share a slot");
}

#[test]
fn the_fiat_tag_is_its_own_domain() {
    // `fiat_commit` is the only tag-first fold without a secret behind it, so its tag is the whole of its
    // domain separation: it must not be any tag the account-side builders use.
    let tags = [
        TAG_REP, TAG_BOND, TAG_HANDLE, TAG_LEAF, TAG_NOTE, TAG_LOCK, TAG_PAIR, TAG_CP, TAG_HINT, TAG_OPERATOR,
        TAG_POOL_CP,
    ];
    for i in 0..11 {
        assert(tags[i] != TAG_FIAT);
        for j in 0..11 {
            if i != j {
                assert(tags[i] != tags[j], "every tag is its own domain");
            }
        }
    }
}

#[test]
fn every_field_of_the_fiat_leg_binds() {
    // One field changed, one commitment changed: a Provider cannot prove a payment that differs from the
    // signed one in rail, currency, amount or payee — and the salt is what hides the rest.
    let base = fiat_commit(1, 986, 150000, 7, 11);
    assert(fiat_commit(2, 986, 150000, 7, 11) != base, "rail");
    assert(fiat_commit(1, 32, 150000, 7, 11) != base, "currency");
    assert(fiat_commit(1, 986, 149999, 7, 11) != base, "amount");
    assert(fiat_commit(1, 986, 150000, 8, 11) != base, "payee");
    assert(fiat_commit(1, 986, 150000, 7, 12) != base, "salt");
}
