// Merkle membership against a PoseidonTree root (§E.3.15.3): the witness format every
// circuit that proves membership consumes — one sibling and one index bit per level,
// hashing pairs with PoseidonT3 exactly as `src/packages/PoseidonTree.sol` does
// (index bit 0: node on the left; bit 1: node on the right).
use crate::commitments::poseidon_t3;
use crate::vectors;

/// Root of the empty tree with `D` levels — zero leaves folded with PoseidonT3, the same
/// seeding PoseidonTree performs at deploy.
pub fn empty_root<let D: u32>() -> Field {
    let mut z: Field = 0;
    for _ in 0..D {
        z = poseidon_t3(z, z);
    }
    z
}

/// Root implied by a membership witness: the leaf's position path and its siblings.
///
/// The direction selects the hash's INPUTS, not between two hashes. A circuit has no branches: an
/// `if` over a witness evaluates both sides and muxes the result, so hashing inside one would cost
/// two Poseidon permutations per level and throw one away. Selecting the operands first costs the
/// two muxes — a handful of constraints — and hashes once. Every membership proof in the protocol
/// walks through here (accounts at depth 32, notes at 20, the registry, the counterparty tree), so
/// the factor of two lands on all of them at once (measured 2026-09-23, ACIR opcodes):
///
///   claim 71.8k → 41.5k   prepare_admit 29.9k → 19.7k   attest_base 26.0k → 15.8k
///   reveal_advanced 25.5k → 15.3k   prepare_passport 25.1k → 14.9k   prepare_bond 17.4k → 11.0k
///   withdraw 15.8k → 9.4k   register_humanity 13.6k → 7.2k
///
/// It barely moves on-chain verification (an UltraHonk verify is ~0.7M gas almost regardless of the
/// circuit behind it); what it buys is proving time and headroom.
pub fn compute_root<let D: u32>(leaf: Field, siblings: [Field; D], indices: [u8; D]) -> Field {
    let mut node = leaf;
    for level in 0..D {
        let bit = indices[level];
        assert(bit < 2, "index bit must be 0 or 1");
        let right = bit as Field; // 0: the node is on the left; 1: on the right
        let sibling = siblings[level];
        let left_in = node + right * (sibling - node);
        let right_in = sibling + right * (node - sibling);
        node = poseidon_t3(left_in, right_in);
    }
    node
}

/// Convenience for circuits: membership against an expected root (the public input).
pub fn is_member<let D: u32>(leaf: Field, siblings: [Field; D], indices: [u8; D], root: Field) -> bool {
    compute_root::<D>(leaf, siblings, indices) == root
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn empty_root_matches() {
    // 8 is the literal the vectors were generated with (turbofish wants a literal in this
    // nargo); the assertion pins the generated TREE_DEPTH to it.
    assert(vectors::TREE_DEPTH == 8, "vectors depth != 8");
    assert(empty_root::<8>() == vectors::TREE_EMPTY_ROOT);
}

#[test]
fn memberships_match() {
    assert(vectors::TREE_DEPTH == 8, "vectors depth != 8");
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[0],
            vectors::TREE_SIBLINGS_0,
            vectors::TREE_INDICES_0,
        ) == vectors::TREE_MEMBERSHIP_ROOT_0,
        "membership 0",
    );
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[1],
            vectors::TREE_SIBLINGS_1,
            vectors::TREE_INDICES_1,
        ) == vectors::TREE_MEMBERSHIP_ROOT_1,
        "membership 1",
    );
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[2],
            vectors::TREE_SIBLINGS_2,
            vectors::TREE_INDICES_2,
        ) == vectors::TREE_MEMBERSHIP_ROOT_2,
        "membership 2",
    );
}
