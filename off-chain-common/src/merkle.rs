use crate::consensus::keccak256;

/// Hashes a raw 71-byte gate leaf into a Merkle leaf hash.
pub fn leaf_hash(leaf: &[u8]) -> [u8; 32] {
    keccak256(&[leaf])
}

/// OpenZeppelin-compatible node hash: sort the pair, then `keccak256(left || right)`.
pub fn commutative_node_hash(a: [u8; 32], b: [u8; 32]) -> [u8; 32] {
    // OpenZeppelin hashes sorted pair (min, max), not positional left/right.
    if a <= b {
        keccak256(&[&a, &b])
    } else {
        keccak256(&[&b, &a])
    }
}

/// Builds Merkle root from pre-hashed leaves using commutative node hashing.
/// On odd levels, the last node is duplicated.
pub fn merkle_root_from_hashes(hashes: &[[u8; 32]]) -> [u8; 32] {
    if hashes.is_empty() {
        return [0u8; 32];
    }

    let mut level: Vec<[u8; 32]> = hashes.to_vec();
    while level.len() > 1 {
        let mut next = Vec::with_capacity(level.len().div_ceil(2));
        let mut i = 0usize;
        while i < level.len() {
            let left = level[i];
            // Duplicate the last node when level width is odd.
            let right = if i + 1 < level.len() {
                level[i + 1]
            } else {
                left
            };
            next.push(commutative_node_hash(left, right));
            i += 2;
        }
        level = next;
    }

    level[0]
}

/// Convenience root builder from raw gate leaves.
pub fn merkle_root(leaves: &[[u8; 71]]) -> [u8; 32] {
    let hashes: Vec<[u8; 32]> = leaves.iter().map(|leaf| leaf_hash(leaf)).collect();
    merkle_root_from_hashes(&hashes)
}

/// Builds a single Merkle inclusion proof for `hashes[index]`.
/// The proof format is directly usable with OpenZeppelin `MerkleProof.verify`.
pub fn merkle_proof_from_hashes(hashes: &[[u8; 32]], index: usize) -> Vec<[u8; 32]> {
    assert!(!hashes.is_empty(), "cannot build proof for empty tree");
    assert!(index < hashes.len(), "proof index out of range");

    let mut proof = Vec::new();
    let mut idx = index;
    let mut level: Vec<[u8; 32]> = hashes.to_vec();

    while level.len() > 1 {
        // Capture sibling hash for current level.
        let sibling = if idx % 2 == 0 {
            if idx + 1 < level.len() {
                level[idx + 1]
            } else {
                level[idx]
            }
        } else {
            level[idx - 1]
        };
        proof.push(sibling);

        let mut next = Vec::with_capacity(level.len().div_ceil(2));
        let mut i = 0usize;
        while i < level.len() {
            let left = level[i];
            let right = if i + 1 < level.len() {
                level[i + 1]
            } else {
                left
            };
            next.push(commutative_node_hash(left, right));
            i += 2;
        }

        // Move to parent position in next level.
        idx /= 2;
        level = next;
    }

    proof
}

/// Local proof verifier equivalent to OpenZeppelin commutative verification.
pub fn verify_proof(leaf: [u8; 32], proof: &[[u8; 32]], root: [u8; 32]) -> bool {
    let mut computed = leaf;
    for sibling in proof {
        computed = commutative_node_hash(computed, *sibling);
    }
    computed == root
}
