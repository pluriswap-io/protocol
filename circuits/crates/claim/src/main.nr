// The terminal delta (PROTOCOLO.md §E.3.15.5, V3 as-built). The proof says, in one: "I know
// the account behind `dealSubject = Poseidon(sk_id, dealId)`; its CURRENT leaf sits in a
// live tree under `repRoot`; `newLeaf` is that leaf with the pending record's terminal
// delta applied — count/volume/penalty/inFlight moved together or not at all, the version
// bumped, the salt re-derived — and `nullRep(v)` is the CURRENT version's nullifier".
//
// The delta values (`kind`, `token`, `principal`) are public inputs the contract reads
// from `pending`: the adapter binds the proof to exactly the record the kernel wrote.
// The delta arithmetic — including "no negative inFlight" — is proven IN-CIRCUIT; the
// contract only trusts the verifier's word.
//
// §E.3.15.5's table, as ARITHMETIC (kind never branches control flow — the negated-guard
// codegen bug of circuits/README.md is a class, and selectors keep the proof's shape
// inside what bb's optimized EVM verifier accepts):
//     Peaceful   count+1, volume+principal   (the CREDIT: fresh counterparty, room in the window, a
//                                            creditable deal — see below)
//                rec_count+1, rec_volume+principal   (the RECORD: always)
//     Silent     —
//     Stalemate  penalty+5
//     ArbWin     —
//     ArbLoss    penalty+15
//     Deadlock   penalty+10   (a dispute nobody settled, in a deal nobody gave a tribunal — 2026-09-24)
//     NoShow     penalty+5    (a Provider who let the fiat clock run out or cancelled alone — 2026-09-28)
//     every kind inFlight−principal
//
// THE RECORD AND THE CREDIT (2026-10-01, the open accounts). A completed deal always lands in the public
// record (`rec_count`, `rec_volume`) — that is what the listing shows as the account's deals. It lands in
// the credit (`count`, `volume`, what buys tier) only when the module says the deal is creditable: both
// sides verified when it activated, or across from a pool, a verified human vouched. `credit` is that
// word, read by the module from its own storage — the prover does not choose it. Penalties ignore it:
// what went wrong costs the same with or without a Passport.
use pluri_commitments::commitments::{
    CP_DEPTH, account_commitment, cp_path, deal_subject, leaf_rep, leaf_salt, null_rep,
    pair_tag as pair_tag_of,
};
use pluri_commitments::merkle::{compute_root, is_member};
use pluri_commitments::vectors as v;

/// How many credited deals fit in one rate window (§E.3.14.7). Sixteen new counterparties in an epoch
/// is far past any honest retail trader and only bites automated bursts.
global CREDITS_PER_EPOCH: u64 = 16;

fn main(
    deal_id: pub Field,
    subject: pub Field,
    new_leaf: pub Field,
    nullifier: pub Field,
    kind: pub Field,
    token: pub Field,
    principal: pub Field,
    rep_root: pub Field,
    // The §E.3.14.7 anti-farming inputs, both read from what the chain already holds: the pair tag the
    // two sides agreed on when they activated (stored per deal by the module), and the epoch the
    // adapter derives from `block.timestamp`. The circuit has no clock of its own, exactly like
    // `attest_base` has none — a public input is how a clock gets in.
    pair_tag: pub Field,
    epoch: pub Field,
    // Whether this deal may credit (1) or only record (0): the module's `creditable[dealId]`.
    credit: pub Field,
    // The account's secret and the current leaf's private fields (§E.3.15.3 leafRep order).
    sk_id: Field,
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // The anti-farming state of the leaf: who has already been credited to this account, and how
    // much of the current rate window is spent.
    cp_root: Field,
    leaf_epoch: Field,
    leaf_credits: Field,
    // The record and the flag (2026-10-01).
    rec_count: Field,
    rec_volume: Field,
    verified: Field,
    // The counterparty of THIS deal, and the slot it occupies in the tree above. `slot` is what the
    // tree currently holds there: zero when free, the counterparty's own `S` when it was already
    // credited, somebody else's on a (astronomically unlikely) collision — which reads as taken, the
    // safe direction.
    s_other: Field,
    // The secret both sides blinded the pair tag with at activation (Anexo R, 2026-09-29). The account
    // recovers it, like `s_other`, from the hint the activation published under its own pad.
    pair_secret: Field,
    slot: Field,
    cp_siblings: [Field; CP_DEPTH],
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    assert(token != 0, "zero token");
    // `kind` is a Close enum (0..6) — the adapter passes `pending.kind`; anything else
    // cannot name a delta (checked here too, so a proof with a foreign kind cannot exist).
    let k: u8 = kind as u8;
    assert(k as Field == kind, "kind too big");
    assert(k <= 6, "unknown close kind");

    // The per-deal binding: the same pseudonym the activation bundle prepared.
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    let s = account_commitment(sk_id);

    // The current leaf: a live member. Its token IS the delta's token — the principal and
    // the inFlight it moves are denominated in it (the prepare put them there together).
    assert(leaf_token == token, "leaf token mismatch");
    let leaf = leaf_rep(
        s,
        count,
        volume,
        penalty,
        in_flight,
        leaf_token,
        leaf_salt(sk_id, version),
        version,
        cp_root,
        leaf_epoch,
        leaf_credits,
        rec_count,
        rec_volume,
        verified,
    );
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");
    // The word the module passes is a bit, and an open account is never on the crediting end of it —
    // the module could not have said so, and the circuit does not take its word for it either.
    assert(credit * (1 - credit) == 0, "credit is a bit");
    assert(credit * (1 - verified) == 0, "credit needs a passport");
    // The current version's nullifier (§E.3.15.3): the claim burns it — one delta per version.
    assert(null_rep(sk_id, version) == nullifier, "version nullifier mismatch");

    // Bounds (this nargo forbids relational ops on Field): every stat cast-checked, the
    // release exact — §E.3.15.5's "no negative inFlight" is this comparison, proven here.
    let cnt: u128 = count as u128;
    assert(cnt as Field == count, "count too big");
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let pen: u128 = penalty as u128;
    assert(pen as Field == penalty, "penalty too big");
    let inf: u128 = in_flight as u128;
    assert(inf as Field == in_flight, "inFlight too big");
    let prin: u128 = principal as u128;
    assert(prin as Field == principal, "principal too big");
    let rcnt: u128 = rec_count as u128;
    assert(rcnt as Field == rec_count, "record count too big");
    let rvol: u128 = rec_volume as u128;
    assert(rvol as Field == rec_volume, "record volume too big");
    assert(inf >= prin, "inFlight under the principal");

    // ---------------------------------------------------------------- who is on the other side
    // The pair, as both sides named it at activation: this proof binds MY commitment and the
    // counterparty's as a witness, and the tag only comes out right if each used the other's real
    // `S` (the multiset {S_a, X} = {S_b, Y} has no other solution when S_a != S_b). So the claim
    // cannot invent a fresh counterparty to be credited by — which is the whole farm, priced.
    assert(pair_tag_of(s, s_other, deal_id, pair_secret) == pair_tag, "pair tag mismatch");

    // The slot that counterparty occupies in MY counterparty tree, at a path derived from its own
    // commitment: a claim cannot aim this proof at whatever empty corner it likes.
    let cp_indices = cp_path(s_other);
    assert(is_member::<CP_DEPTH>(slot, cp_siblings, cp_indices, cp_root), "counterparty slot mismatch");
    // Free slot = nobody has been credited from this account yet. Anything else reads as taken:
    // their own `S` because they already credited me, or (at 2^-32 per pair) a stranger's on a
    // collision — which denies a credit rather than granting one, the direction to fail in.
    let is_fresh = (slot == 0) as Field;

    // ---------------------------------------------------------------- the rate window
    // The window resets when the epoch moves; within one, at most CREDITS_PER_EPOCH credits. It
    // cannot stop a patient farmer and is not meant to: it turns a weekend into a year, during
    // which the account is exposed to every penalty everyone else is.
    let same_epoch = (epoch == leaf_epoch) as Field;
    let credits_so_far = same_epoch * leaf_credits;
    let c_so_far: u64 = credits_so_far as u64;
    assert(c_so_far as Field == credits_so_far, "credit counter too big");
    let has_room = (c_so_far < CREDITS_PER_EPOCH) as Field;

    // §E.3.15.5's table as arithmetic: kind's selectors pick the completed-deal reward and
    // the penalties; every kind releases the principal from flight.
    //
    // The 2026-09-23 amendment is the `credits` factor on the REWARD and nothing else: a completed
    // deal counts when the counterparty is new to this account and the window has room. What went
    // wrong is never deduplicated — a stalemate with somebody you have already traded with costs
    // exactly what a stalemate costs. Good things are earned per person; bad things are just true.
    let is_peaceful = (k == 0) as Field;
    let is_stalemate = (k == 2) as Field;
    let is_arbloss = (k == 4) as Field;
    let is_deadlock = (k == 5) as Field;
    let is_no_show = (k == 6) as Field;
    let credits = is_peaceful * credit * is_fresh * has_room;
    let new_count = count + credits;
    let new_volume = volume + credits * principal;
    // The record takes every completed deal: no pair rule, no window, no Passport.
    let new_rec_count = rec_count + is_peaceful;
    let new_rec_volume = rec_volume + is_peaceful * principal;
    let new_penalty = penalty + is_stalemate * 5 + is_arbloss * 15 + is_deadlock * 10 + is_no_show * 5;
    let new_in_flight = in_flight - principal;
    // The moved stats stay canonical (a delta cannot push a stat past the u128 domain the
    // account's later proofs read it in).
    let nc: u128 = new_count as u128;
    assert(nc as Field == new_count, "count overflow");
    let nv: u128 = new_volume as u128;
    assert(nv as Field == new_volume, "volume overflow");
    let np: u128 = new_penalty as u128;
    assert(np as Field == new_penalty, "penalty overflow");
    let nrc: u128 = new_rec_count as u128;
    assert(nrc as Field == new_rec_count, "record count overflow");
    let nrv: u128 = new_rec_volume as u128;
    assert(nrv as Field == new_rec_volume, "record volume overflow");

    // The counterparty tree moves exactly when the credit does: the slot is taken by the account
    // that just earned it. Taking it on every terminal instead would let a stranger burn your credit
    // slot with a cheap Silent deal; taking it only here keeps the invariant readable — the tree
    // holds the accounts that have credited you, and nobody else.
    let taken_root = compute_root::<CP_DEPTH>(s_other, cp_siblings, cp_indices);
    let new_cp_root = credits * taken_root + (1 - credits) * cp_root;
    // The window: rolled to this epoch, spent by this credit.
    let new_credits = credits_so_far + credits;

    // The delta leaf (§E.3.15.5): stats moved together, version bumped, salt re-derived.
    assert(
        leaf_rep(
            s,
            new_count,
            new_volume,
            new_penalty,
            new_in_flight,
            token,
            leaf_salt(sk_id, version + 1),
            version + 1,
            new_cp_root,
            epoch,
            new_credits,
            new_rec_count,
            new_rec_volume,
            verified,
        ) == new_leaf,
        "delta leaf mismatch",
    );
}


// ---------------------------------------------------------------- parity tests (vectors.nr)

/// The witness a claim of the pinned sample carries, in one place: the sample is a FRESH counterparty
/// against an empty tree and a cold window, so it credits when the deal is creditable.
fn sample_main(
    kind: Field,
    new_leaf: Field,
    slot: Field,
    epoch: Field,
    leaf_epoch: Field,
    leaf_credits: Field,
    credit: Field,
) {
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        new_leaf,
        v::CLAIM_NULL_REP,
        kind,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_ROOT,
        v::CLAIM_PAIR_TAG,
        epoch,
        credit,
        v::CLAIM_SK_ID,
        v::CLAIM_COUNT,
        v::CLAIM_VOLUME,
        v::CLAIM_PENALTY,
        v::CLAIM_IN_FLIGHT,
        v::CLAIM_LEAF_TOKEN,
        v::CLAIM_VERSION,
        v::CLAIM_CP_ROOT,
        leaf_epoch,
        leaf_credits,
        v::CLAIM_REC_COUNT,
        v::CLAIM_REC_VOLUME,
        1,
        v::CLAIM_CP_S,
        v::CLAIM_PAIR_SECRET,
        slot,
        v::CLAIM_CP_SIBLINGS,
        v::CLAIM_SIBLINGS,
        v::CLAIM_INDICES,
    );
}

/// The delta leaf of the sample for a given kind, with the counterparty state it should end in.
fn sample_leaf(
    count: Field,
    volume: Field,
    penalty: Field,
    cp_root: Field,
    epoch: Field,
    credits: Field,
    rec_count: Field,
    rec_volume: Field,
) -> Field {
    leaf_rep(
        account_commitment(v::CLAIM_SK_ID),
        count,
        volume,
        penalty,
        v::CLAIM_IN_FLIGHT - v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        leaf_salt(v::CLAIM_SK_ID, v::CLAIM_VERSION + 1),
        v::CLAIM_VERSION + 1,
        cp_root,
        epoch,
        credits,
        rec_count,
        rec_volume,
        1,
    )
}

/// One of the two repeat-shaped scenarios (`claim_repeat`, `claim_full`): the current leaf is what a second
/// admission wrote after the first claim — one credited deal, one recorded deal, the principal in flight.
fn second_deal_main(
    kind: Field,
    new_leaf: Field,
    null_rep: Field,
    root: Field,
    epoch: Field,
    version: Field,
    cp_root: Field,
    credits: Field,
    slot: Field,
    cp_siblings: [Field; CP_DEPTH],
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        new_leaf,
        null_rep,
        kind,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        root,
        v::CLAIM_PAIR_TAG,
        epoch,
        1,
        v::CLAIM_SK_ID,
        1, // the count the first claim left
        v::CLAIM_PRINCIPAL,
        0,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        version,
        cp_root,
        epoch,
        credits,
        1, // and the record it left
        v::CLAIM_PRINCIPAL,
        1,
        v::CLAIM_CP_S,
        v::CLAIM_PAIR_SECRET,
        slot,
        cp_siblings,
        siblings,
        indices,
    );
}

#[test]
fn claim_sample_verifies() {
    // The pinned sample (vectors.json `claim`): the prepare deal ends Peaceful — the current leaf is
    // the prepare's new leaf (version 1, the 100_000_000 principal in flight), and the delta completes
    // the deal: count 1, volume +principal, the same in the record, the flight released, the
    // counterparty written into the tree and one credit spent in the window.
    assert(v::CLAIM_DEPTH == 32, "account tree depth");
    sample_main(v::CLAIM_KIND, v::CLAIM_NEW_LEAF, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS, 1);
}

#[test]
fn the_pair_is_named_by_both_or_by_neither() {
    // The soundness of the whole anti-farming rule, stated as arithmetic: the tag is commutative over
    // the two account commitments, so the value this claim proves is the same one the COUNTERPARTY's
    // own proof produced at activation. Neither side can move it alone.
    let s = account_commitment(v::CLAIM_SK_ID);
    assert(
        pair_tag_of(s, v::CLAIM_CP_S, v::CLAIM_DEAL_ID, v::CLAIM_PAIR_SECRET) == v::CLAIM_PAIR_TAG,
        "the tag is the pair's",
    );
    assert(
        pair_tag_of(v::CLAIM_CP_S, s, v::CLAIM_DEAL_ID, v::CLAIM_PAIR_SECRET) == v::CLAIM_PAIR_TAG,
        "and it does not care who computes it",
    );
}

#[test(should_fail_with = "pair tag mismatch")]
fn a_counterparty_of_your_own_invention_has_no_proof() {
    // The farm, refused at its root. A claim that wants a SECOND credit from the same partner cannot
    // simply name somebody else: the tag was fixed when the deal activated, by both sides at once.
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        v::CLAIM_NEW_LEAF,
        v::CLAIM_NULL_REP,
        v::CLAIM_KIND,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_ROOT,
        v::CLAIM_PAIR_TAG,
        v::CLAIM_EPOCH,
        1,
        v::CLAIM_SK_ID,
        v::CLAIM_COUNT,
        v::CLAIM_VOLUME,
        v::CLAIM_PENALTY,
        v::CLAIM_IN_FLIGHT,
        v::CLAIM_LEAF_TOKEN,
        v::CLAIM_VERSION,
        v::CLAIM_CP_ROOT,
        v::CLAIM_EPOCH_IN,
        v::CLAIM_EPOCH_CREDITS,
        v::CLAIM_REC_COUNT,
        v::CLAIM_REC_VOLUME,
        1,
        v::CLAIM_CP_S + 1,
        v::CLAIM_PAIR_SECRET, // somebody who was never on the other side of this deal
        0,
        v::CLAIM_CP_SIBLINGS,
        v::CLAIM_SIBLINGS,
        v::CLAIM_INDICES,
    );
}

#[test]
fn the_second_deal_with_the_same_account_earns_nothing() {
    // The rule itself, end to end against its own pinned leaf (vectors `claim_repeat`): the account
    // has already been credited by this counterparty, so its slot holds their `S`. A Peaceful
    // terminal releases the flight and moves no CREDIT — no count, no volume, the tree untouched.
    // Five more of these are still one credit, which is exactly what a closed cluster is worth. The
    // record does take it: the listing counts deals, the tier counts people.
    second_deal_main(
        0, // Peaceful
        v::CLAIM_REPEAT_NEW_LEAF,
        v::CLAIM_REPEAT_NULL_REP,
        v::CLAIM_REPEAT_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_VERSION,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_CREDITS,
        v::CLAIM_REPEAT_SLOT,
        v::CLAIM_REPEAT_CP_SIBLINGS,
        v::CLAIM_REPEAT_SIBLINGS,
        v::CLAIM_REPEAT_INDICES,
    );
}

#[test]
fn a_full_window_earns_nothing_either() {
    // The rate limit, same shape (vectors `claim_full`): a counterparty this account has never been
    // credited by, but sixteen credits already spent in this epoch. The credit is refused and not
    // deferred — and the slot stays FREE, so the pair can still credit once in a later window. A
    // limit that let the credit come back tomorrow would only be a delay.
    second_deal_main(
        0, // Peaceful
        v::CLAIM_FULL_NEW_LEAF,
        v::CLAIM_FULL_NULL_REP,
        v::CLAIM_FULL_ROOT,
        v::CLAIM_FULL_EPOCH,
        v::CLAIM_FULL_VERSION,
        v::CLAIM_FULL_CP_ROOT,
        v::CLAIM_FULL_CREDITS,
        v::CLAIM_FULL_SLOT,
        v::CLAIM_FULL_CP_SIBLINGS,
        v::CLAIM_FULL_SIBLINGS,
        v::CLAIM_FULL_INDICES,
    );
}

#[test]
fn a_penalty_is_never_deduplicated() {
    // The asymmetry that makes the rule safe to have. The same counterparty as above — slot taken, no
    // credit possible — but the deal ends in a stalemate, and that costs exactly what a stalemate
    // costs. Good things are earned once per person; bad things are simply true.
    let punished = leaf_rep(
        account_commitment(v::CLAIM_SK_ID),
        1,
        v::CLAIM_PRINCIPAL,
        5, // the penalty landed
        0,
        v::CLAIM_TOKEN,
        leaf_salt(v::CLAIM_SK_ID, v::CLAIM_REPEAT_VERSION + 1),
        v::CLAIM_REPEAT_VERSION + 1,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_CREDITS,
        1, // a stalemate is not a completed deal: the record does not move either
        v::CLAIM_PRINCIPAL,
        1,
    );
    second_deal_main(
        2, // Stalemate
        punished,
        v::CLAIM_REPEAT_NULL_REP,
        v::CLAIM_REPEAT_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_VERSION,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_CREDITS,
        v::CLAIM_REPEAT_SLOT,
        v::CLAIM_REPEAT_CP_SIBLINGS,
        v::CLAIM_REPEAT_SIBLINGS,
        v::CLAIM_REPEAT_INDICES,
    );
}

#[test]
fn every_close_kind_matches_the_table() {
    // §E.3.15.5's table, all seven rows, against a FRESH counterparty — the case the table was always
    // describing. Silent and ArbWin release only the flight; Stalemate/ArbLoss/Deadlock/NoShow punish;
    // Peaceful completes, and only Peaceful takes the counterparty's slot and a credit from the window.
    assert(v::DELTA_COUNT == 7, "seven close kinds");
    for i in 0..7 {
        let kind = v::DELTA_KINDS[i];
        let credits = (kind == 0) as Field;
        let expected = sample_leaf(
            v::DELTA_NEW_COUNTS[i],
            v::DELTA_NEW_VOLUMES[i],
            v::DELTA_NEW_PENALTIES[i],
            credits * v::CLAIM_CP_ROOT_AFTER + (1 - credits) * v::CLAIM_CP_ROOT,
            v::CLAIM_EPOCH,
            credits,
            v::DELTA_NEW_COUNTS[i],
            v::DELTA_NEW_VOLUMES[i],
        );
        // The proof's own arithmetic: selectors against the row's expected stats.
        let is_peaceful = (kind == 0) as Field;
        let is_stalemate = (kind == 2) as Field;
        let is_arbloss = (kind == 4) as Field;
        let is_deadlock = (kind == 5) as Field;
        let is_no_show = (kind == 6) as Field;
        let new_count = v::CLAIM_COUNT + is_peaceful;
        let new_volume = v::CLAIM_VOLUME + is_peaceful * v::CLAIM_PRINCIPAL;
        let new_penalty =
            v::CLAIM_PENALTY + is_stalemate * 5 + is_arbloss * 15 + is_deadlock * 10 + is_no_show * 5;
        let new_in_flight = v::CLAIM_IN_FLIGHT - v::CLAIM_PRINCIPAL;
        assert(new_count == v::DELTA_NEW_COUNTS[i], "row count");
        assert(new_volume == v::DELTA_NEW_VOLUMES[i], "row volume");
        assert(new_penalty == v::DELTA_NEW_PENALTIES[i], "row penalty");
        assert(new_in_flight == v::DELTA_NEW_IN_FLIGHTS[i], "row inFlight");
        sample_main(kind, expected, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS, 1);
    }
}

#[test]
fn a_deal_that_cannot_credit_still_records() {
    // The same table with `credit = 0`: the deal had an open account on one side (2026-10-01). The fresh
    // counterparty does not matter, nor the empty window: the credit does not move, the counterparty's slot
    // stays free — so the day both are verified, their first deal together still credits — and the window
    // spends nothing. The record takes the completed deal anyway, and every penalty lands as it always does.
    for i in 0..7 {
        let kind = v::DELTA_KINDS[i];
        let expected = sample_leaf(
            0,
            0,
            v::DELTA_NEW_PENALTIES[i],
            v::CLAIM_CP_ROOT,
            v::CLAIM_EPOCH,
            0,
            v::DELTA_NEW_COUNTS[i],
            v::DELTA_NEW_VOLUMES[i],
        );
        sample_main(kind, expected, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS, 0);
    }
}

#[test(should_fail_with = "delta leaf mismatch")]
fn an_uncreditable_deal_cannot_take_the_credit() {
    // The credited leaf, claimed under `credit = 0`: there is no witness for it.
    sample_main(v::CLAIM_KIND, v::CLAIM_NEW_LEAF, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS, 0);
}

#[test(should_fail_with = "credit is a bit")]
fn the_credit_word_is_a_bit() {
    sample_main(v::CLAIM_KIND, v::CLAIM_NEW_LEAF, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS, 2);
}

/// The open account's own claim (vectors `claim_open`): its activation leaf (version 1, the principal in
/// flight, `verified = 0`) ends Peaceful.
fn open_main(new_leaf: Field, credit: Field) {
    main(
        v::CLAIM_DEAL_ID,
        v::OPEN_DEAL_SUBJECT,
        new_leaf,
        v::CLAIM_OPEN_NULL_REP,
        0,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_OPEN_ROOT,
        v::OPEN_PAIR_TAG,
        v::CLAIM_EPOCH,
        credit,
        v::OPEN_SK_ID,
        0,
        0,
        0,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        1,
        v::CLAIM_CP_ROOT,
        0,
        0,
        0,
        0,
        0,
        v::OPEN_CP_S,
        v::CLAIM_PAIR_SECRET,
        0,
        v::OPEN_CP_SIBLINGS,
        v::CLAIM_OPEN_SIBLINGS,
        v::CLAIM_OPEN_INDICES,
    );
}

#[test]
fn an_open_account_records_its_deal() {
    // Record +1 and +principal, credit untouched, still unverified.
    open_main(v::CLAIM_OPEN_NEW_LEAF, 0);
}

#[test(should_fail_with = "credit needs a passport")]
fn an_open_account_is_never_credited() {
    // Even if a module said so: the leaf's own flag is what the circuit reads.
    open_main(v::CLAIM_OPEN_NEW_LEAF, 1);
}
