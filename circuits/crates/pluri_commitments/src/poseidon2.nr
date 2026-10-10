// Circomlib PoseidonT2 over BN254 (one input + capacity): 8 full rounds + 56 partial
// rounds, x^5 S-box, state = [capacity, input], output = state[0]. This is the width of
// `S = Poseidon(sk_id)` — the only single-input commitment of §E.3.15.3.
//
// Round structure mirrors iden3/circomlibjs `poseidon_reference.js`: every round adds t
// constants (one per lane), full rounds sbox every lane, partial rounds sbox lane 0
// only, every round mixes with the row-major MDS matrix (state'[i] = Σ_j M[i][j]*state[j]).
use crate::constants_p2::{C, M};

global T: u32 = 2;
global N_ROUNDS_F: u32 = 8;
global N_ROUNDS_P: u32 = 56;

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
