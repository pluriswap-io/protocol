// Circomlib PoseidonT3 over BN254 (two inputs + capacity): 8 full rounds + 57 partial
// rounds, x^5 S-box, state = [capacity, in0, in1], output = state[0]. The workhorse of
// the private layer: tree node hashing (PoseidonTree hashes pairs), and the primitive of
// every multi-field commitment chain (the pinned left fold of §E.3.15.3).
//
// Round structure mirrors iden3/circomlibjs `poseidon_reference.js`, with the parameters
// of the circomlib PoseidonT3 template — the exact permutation poseidon-solidity runs
// on-chain, pinned by the vector `poseidonperm_x5_254_3([1,2])`.
use crate::constants_p3::{C, M};

global T: u32 = 3;
global N_ROUNDS_F: u32 = 8;
global N_ROUNDS_P: u32 = 57;

fn pow5(x: Field) -> Field {
    let sq = x * x;
    sq * sq * x
}

fn mix(state: [Field; T]) -> [Field; T] {
    let mut out: [Field; T] = state; // overwritten lane by lane below
    for i in 0..T {
        let mut acc = 0;
        for j in 0..T {
            acc = acc + M[i * T + j] * state[j];
        }
        out[i] = acc;
    }
    out
}

pub fn permutation(state: [Field; T]) -> [Field; T] {
    let mut st = state;
    for r in 0..(N_ROUNDS_F + N_ROUNDS_P) {
        for i in 0..T {
            st[i] = st[i] + C[r * T + i];
        }
        if (r < N_ROUNDS_F / 2) | (r >= N_ROUNDS_F / 2 + N_ROUNDS_P) {
            for i in 0..T {
                st[i] = pow5(st[i]);
            }
        } else {
            st[0] = pow5(st[0]);
        }
        st = mix(st);
    }
    st
}
