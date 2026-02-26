use crate::consensus::{keccak256, uint256_from_u64};

/// Contract-consensus gate block hash:
/// `keccak256(abi.encodePacked(gateIndex, leafBytes))`.
pub fn gc_block_hash(gate_index: u64, leaf: &[u8]) -> [u8; 32] {
    let idx = uint256_from_u64(gate_index);
    keccak256(&[&idx, leaf])
}

/// One incremental transition:
/// `IH_i = keccak256(abi.encodePacked(IH_{i-1}, blockHash_i))`.
pub fn inc_hash(prev: [u8; 32], block_hash: [u8; 32]) -> [u8; 32] {
    keccak256(&[&prev, &block_hash])
}

/// Terminal incremental state over ordered gate block hashes.
pub fn incremental_root_from_hashes(block_hashes: &[[u8; 32]]) -> [u8; 32] {
    let mut state = [0u8; 32];
    for h in block_hashes {
        state = inc_hash(state, *h);
    }
    state
}

/// Convenience terminal-state builder from raw gate leaves.
pub fn incremental_root(leaves: &[[u8; 71]]) -> [u8; 32] {
    let block_hashes: Vec<[u8; 32]> = leaves
        .iter()
        .enumerate()
        .map(|(gate_index, leaf)| gc_block_hash(gate_index as u64, leaf))
        .collect();
    incremental_root_from_hashes(&block_hashes)
}

/// Builds contract-compatible IH proof for a challenged gate block.
///
/// Proof format mirrors Solidity `_processIncrementalProof`:
/// - `[]` if there is only one block.
/// - otherwise:
///   - `proof[0] = IH_{index-1}` (prefix state before challenged block),
///   - `proof[1..] = block_hash_{index+1..end}` (ordered suffix blocks).
pub fn ih_proof_from_hashes(block_hashes: &[[u8; 32]], index: usize) -> Vec<[u8; 32]> {
    assert!(!block_hashes.is_empty(), "cannot build IH proof for empty chain");
    assert!(index < block_hashes.len(), "IH proof index out of range");

    if block_hashes.len() == 1 {
        return Vec::new();
    }

    let mut prefix_state = [0u8; 32];
    for h in block_hashes.iter().take(index) {
        prefix_state = inc_hash(prefix_state, *h);
    }

    let mut proof = Vec::with_capacity(1 + block_hashes.len().saturating_sub(index + 1));
    proof.push(prefix_state);
    for h in block_hashes.iter().skip(index + 1) {
        proof.push(*h);
    }
    proof
}

/// Local verifier equivalent to Solidity `_processIncrementalProof`.
pub fn verify_ih_proof(block_hash: [u8; 32], ih_proof: &[[u8; 32]], root: [u8; 32]) -> bool {
    let mut state = if ih_proof.is_empty() {
        inc_hash([0u8; 32], block_hash)
    } else {
        inc_hash(ih_proof[0], block_hash)
    };

    for h in ih_proof.iter().skip(1) {
        state = inc_hash(state, *h);
    }

    state == root
}
