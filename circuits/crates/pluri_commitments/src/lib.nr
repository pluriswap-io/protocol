// The canonical commitments library of the private layer (PROTOCOLO.md §E.3.15.3, as
// amended by the canonical-encoding decision of the verifier work). One implementation
// per language, one set of vectors: Noir (this crate), JS (circuits/js/lib/commitments.ts)
// and Solidity (src/packages/libraries/PrivacyCommitments.sol) all compute the identical
// commitments, pinned by test/fixtures/vectors.json.
//
// Poseidon here is vendored with circomlib parameters (constants_p2/constants_p3,
// generated from circomlibjs): Noir's std poseidon is deliberately NOT used — the
// protocol's parameters are circomlib's, pinned on-chain by poseidon-solidity.
pub mod commitments;
pub mod constants_p2;
pub mod constants_p3;
pub mod merkle;
pub mod poseidon2;
pub mod poseidon3;
pub mod tiers;
pub mod vectors;
