//! Deterministic parity vectors for consensus-critical Rust logic.
//! If any expected hash changes, Rust behavior has diverged from the frozen rules.

use off_chain_common::consensus::{
    LEAF_BYTES_LEN, compute_row_key, derive_wire_flip_bit, derive_wire_label, expand_pad,
    layout_leaf_hash,
};
use off_chain_common::garble::{garble_circuit, recompute_gate_leaf};
use off_chain_common::ih::{gc_block_hash, ih_proof_from_hashes, incremental_root, verify_ih_proof};
use off_chain_common::labels::get_permutation_bit;
use off_chain_common::types::{CircuitLayout, GateDesc, GateType};

fn base_inputs() -> ([u8; 32], [u8; 32], u64) {
    // Shared fixture used by all vector checks.
    ([0x11u8; 32], [0x22u8; 32], 3u64)
}

#[test]
fn consensus_vectors_are_stable() {
    let (circuit_id, seed, instance_id) = base_inputs();

    let flip = derive_wire_flip_bit(circuit_id, instance_id, 7, seed);
    let l0 = derive_wire_label(circuit_id, instance_id, 7, 0, seed);
    let l1 = derive_wire_label(circuit_id, instance_id, 7, 1, seed);
    let rk = compute_row_key(circuit_id, instance_id, 9, 1, 0, l0, l1);
    let pad = expand_pad(rk);

    // Exact vectors pinned for regression detection.
    assert_eq!(flip, 0);
    assert_eq!(hex::encode(l0), "3667830a11a80dfdcf6a29b50556965e");
    assert_eq!(hex::encode(l1), "0db9552d18bd2b3c74916fba82eed9dd");
    assert_eq!(
        hex::encode(rk),
        "557b9944ac0a06f47e3e20298a714731a41d3bb1262ed7cf3eb0eb5780431eee"
    );
    assert_eq!(hex::encode(pad), "afb11f98b824d517cfa83fd73431aaac");
}

#[test]
fn permutation_bits_follow_flip_xor_semantic() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let flip = derive_wire_flip_bit(circuit_id, instance_id, 7, seed);
    let l0 = derive_wire_label(circuit_id, instance_id, 7, 0, seed);
    let l1 = derive_wire_label(circuit_id, instance_id, 7, 1, seed);

    // point-and-permute invariant.
    assert_eq!(get_permutation_bit(l0), flip);
    assert_eq!(get_permutation_bit(l1), flip ^ 1);
}

#[test]
fn gate_leaf_matches_deterministic_vector() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let gate = GateDesc::new(GateType::And, 7, 8, 9);
    let leaf = recompute_gate_leaf(seed, circuit_id, instance_id, 9, gate);

    // Leaf encoding and index-bound block hash must remain byte-stable.
    assert_eq!(leaf.len(), LEAF_BYTES_LEN);
    assert_eq!(
        hex::encode(gc_block_hash(9, &leaf)),
        "a300af318eda049428eb239539c1f40283d72dc07b6dfc33795294dceacc15a0"
    );
    assert_eq!(
        hex::encode(layout_leaf_hash(9, gate)),
        "77e8fea17177263b25687abafa2631d7e6915106d7cf6ec47feb3b086fe2a97c"
    );
}

#[test]
fn not_gate_rows_are_zero() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let gate = GateDesc::new(GateType::Not, 4, 0, 5);
    let leaf = recompute_gate_leaf(seed, circuit_id, instance_id, 2, gate);

    // Header is present; ciphertext rows are canonical zeros.
    assert_eq!(leaf[0], GateType::Not as u8);
    assert!(leaf[7..].iter().all(|b| *b == 0));
}

#[test]
fn whole_circuit_and_incremental_root_are_stable() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let layout = CircuitLayout {
        circuit_id,
        instance_id,
        gates: vec![
            GateDesc::new(GateType::And, 0, 1, 2),
            GateDesc::new(GateType::Xor, 2, 3, 4),
            GateDesc::new(GateType::Not, 4, 0, 5),
        ],
    };

    let leaves = garble_circuit(seed, &layout);
    assert_eq!(leaves.len(), 3);
    assert!(leaves.iter().all(|l| l.len() == LEAF_BYTES_LEN));

    // Root is pinned against current section-5.2 incremental construction.
    let root = incremental_root(&leaves);
    assert_eq!(
        hex::encode(root),
        "73a30bddec1ceb66e2680dd54321f734ac92b0388ee232009ed0b45edb7a3fe8"
    );
}

#[test]
fn ih_proof_roundtrip_matches_contract_style_hashing() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let layout = CircuitLayout {
        circuit_id,
        instance_id,
        gates: vec![
            GateDesc::new(GateType::And, 0, 1, 2),
            GateDesc::new(GateType::Xor, 2, 3, 4),
            GateDesc::new(GateType::Not, 4, 0, 5),
            GateDesc::new(GateType::And, 5, 6, 7),
        ],
    };

    let leaves = garble_circuit(seed, &layout);
    let block_hashes: Vec<[u8; 32]> = leaves
        .iter()
        .enumerate()
        .map(|(idx, leaf)| gc_block_hash(idx as u64, leaf))
        .collect();
    let root = incremental_root(&leaves);

    let idx = 2usize;
    let proof = ih_proof_from_hashes(&block_hashes, idx);
    // Local verifier must accept the generated incremental proof.
    assert!(verify_ih_proof(block_hashes[idx], &proof, root));
}

#[tokio::test]
async fn tokio_guard_smoke() {
    let (circuit_id, seed, instance_id) = base_inputs();
    let gate = GateDesc::new(GateType::Xor, 1, 2, 3);
    let leaf = recompute_gate_leaf(seed, circuit_id, instance_id, 0, gate);
    // Async runtime sanity check for future async integration.
    assert_eq!(leaf.len(), LEAF_BYTES_LEN);
}
