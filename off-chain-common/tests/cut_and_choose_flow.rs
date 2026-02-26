//! End-to-end cut-and-choose smoke test:
//! build N instances, open N-1, and verify gate + layout proofs.

use off_chain_common::consensus::{keccak256, layout_leaf_hash};
use off_chain_common::garble::garble_circuit;
use off_chain_common::ih::{gc_block_hash, ih_proof_from_hashes, incremental_root_from_hashes, verify_ih_proof};
use off_chain_common::merkle::{merkle_proof_from_hashes, merkle_root_from_hashes, verify_proof};
use off_chain_common::scenario::{build_millionaires_layout, com_seed, derive_instance_seed, CUT_AND_CHOOSE_N};
use off_chain_common::types::CircuitLayout;

#[test]
fn generates_10_instances_and_valid_gate_proofs() {
    let n = CUT_AND_CHOOSE_N;
    let m = 7usize;
    let gate_index = 15usize;

    let circuit_id = keccak256(&[b"millionaires-yao-v1"]);
    let master_seed = keccak256(&[b"master-seed-v1"]);
    let gates = build_millionaires_layout(8);
    assert!(gate_index < gates.len());

    let layout_leaf_hashes: Vec<[u8; 32]> = gates
        .iter()
        .enumerate()
        .map(|(idx, gate)| layout_leaf_hash(idx as u64, *gate))
        .collect();
    // This is what the contract stores as `circuitLayoutRoot`.
    let layout_root = merkle_root_from_hashes(&layout_leaf_hashes);
    let layout_proof = merkle_proof_from_hashes(&layout_leaf_hashes, gate_index);

    // Open set after Bob chooses m.
    let open_indices: Vec<usize> = (0..n).filter(|idx| *idx != m).collect();
    assert_eq!(open_indices.len(), n - 1);

    let challenge_instance = open_indices[0];

    let mut root_count = 0usize;
    for instance_id in 0..n {
        let seed = derive_instance_seed(master_seed, circuit_id, instance_id as u64);
        // Phase-2 commitment value that will be checked in revealOpenings.
        let commitment = com_seed(seed);
        assert_ne!(commitment, [0u8; 32]);

        let layout = CircuitLayout {
            circuit_id,
            instance_id: instance_id as u64,
            gates: gates.clone(),
        };
        let leaves = garble_circuit(seed, &layout);
        let block_hashes: Vec<[u8; 32]> = leaves
            .iter()
            .enumerate()
            .map(|(idx, leaf)| gc_block_hash(idx as u64, leaf))
            .collect();
        let root_gc = incremental_root_from_hashes(&block_hashes);
        assert_ne!(root_gc, [0u8; 32]);
        root_count += 1;

        if instance_id == challenge_instance {
            // Prove challenged gate exists in instance root.
            let proof_gc = ih_proof_from_hashes(&block_hashes, gate_index);
            let block_hash = block_hashes[gate_index];
            assert!(verify_ih_proof(block_hash, &proof_gc, root_gc));

            // Prove gate descriptor exists in layout commitment.
            let layout_leaf = layout_leaf_hash(gate_index as u64, gates[gate_index]);
            assert!(verify_proof(layout_leaf, &layout_proof, layout_root));
        }
    }

    assert_eq!(root_count, n);
}
