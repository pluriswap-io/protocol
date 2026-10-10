// The humanity circuit of the register bundle (PROTOCOLO.md §E.3.15.9, V1 as-built):
// "I know the per-human secret `hsk` whose identity commitment `PoseidonT2(hsk)` sits in
// the live humanity registry tree, and `hn = PoseidonT3(hsk, registryId)`."
//
// Registry model (§E.3.15.3 "Registro", Semaphore-style): the registry checks the Passport
// decoder on-chain AT ENROLL — the anchor is necessarily revealed to the registry there —
// and stores only the commitment. Deriving hn from the anchor would therefore be enumerable
// by any decoder observer; hn derives from the secret instead, and one anchor enrolls one
// hsk (registry-enforced), so one human still burns exactly one hn, forever.
//
// Public inputs (signature order, the adapter's amplification checks the last two):
//   h_n         the humanity nullifier the passport burns;
//   root        the registry tree root — the adapter validates it against the ring buffer;
//   registry_id the registry domain — the adapter pins it to THE served registry instance.
use pluri_commitments::commitments::{account_commitment, hn};
use pluri_commitments::merkle::compute_root;
use pluri_commitments::vectors as v;

/// The enrollment tree depth of `HumanityRegistry` (1M anchors). A protocol constant:
/// the deployed registry's tree is exactly this deep, and the witness is exactly this long.
global DEPTH: u32 = 20;

fn main(
    h_n: pub Field,
    root: pub Field,
    registry_id: pub Field,
    hsk: Field,
    siblings: [Field; DEPTH],
    indices: [u8; DEPTH],
) {
    // The identity commitment must sit in the live registry tree (root is a public input —
    // a root the registry never knew fails closed at the adapter).
    let commitment = account_commitment(hsk);
    assert(compute_root::<20>(commitment, siblings, indices) == root, "identity not in registry tree");
    // The humanity nullifier derives from the secret, never from the revealed anchor.
    assert(hn(hsk, registry_id) == h_n, "hn mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn membership_matches_vectors() {
    assert(v::REGISTRY_DEPTH == 20, "vectors registry depth != 20");
    assert(
        compute_root::<20>(
            account_commitment(v::REGISTRY_HSK),
            v::REGISTRY_SIBLINGS,
            v::REGISTRY_INDICES,
        ) == v::REGISTRY_ROOT,
        "registry membership",
    );
    assert(account_commitment(v::REGISTRY_HSK) == v::REGISTRY_IDENTITY_COMMITMENT, "identity commitment");
}

#[test]
fn hn_matches_vectors() {
    assert(hn(v::REGISTRY_HSK, v::REGISTRY_ID) == v::REGISTRY_SAMPLE_HN, "sample hn");
}
