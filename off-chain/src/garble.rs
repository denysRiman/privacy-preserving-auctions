use crate::consensus::{
    compute_row_key, derive_wire_flip_bit, derive_wire_label, encode_leaf, expand_pad, truth_table,
    xor16,
};
use crate::types::{CircuitLayout, GateDesc, GateType};

/// Recomputes one 71-byte gate leaf from `(seed, instance, gateIndex, gateDesc)`.
/// This mirrors Solidity `recomputeGateLeafBytes`, including:
/// - row ordering `rowIndex = 2*permA + permB`
/// - canonical NOT gate rows of zero.
pub fn recompute_gate_leaf(
    seed: [u8; 32],
    circuit_id: [u8; 32],
    instance_id: u64,
    gate_index: u64,
    gate: GateDesc,
) -> [u8; 71] {
    // Four ciphertext rows, each 16 bytes.
    let mut rows = [[0u8; 16]; 4];

    if gate.gate_type != GateType::Not {
        // Flip bits define mapping between permutation bits and semantic bits.
        let flip_a = derive_wire_flip_bit(circuit_id, instance_id, gate.wire_a, seed);
        let flip_b = derive_wire_flip_bit(circuit_id, instance_id, gate.wire_b, seed);

        // Enumerate permutation rows in 2x2 space.
        for perm_a in 0..=1 {
            for perm_b in 0..=1 {
                // Inverse mapping: semantic = permutation XOR flip.
                let bit_a = perm_a ^ flip_a;
                let bit_b = perm_b ^ flip_b;
                let out_bit = truth_table(gate.gate_type, bit_a, bit_b);

                // Deterministic input/output labels for this truth-table point.
                let label_a = derive_wire_label(circuit_id, instance_id, gate.wire_a, bit_a, seed);
                let label_b = derive_wire_label(circuit_id, instance_id, gate.wire_b, bit_b, seed);
                let out_label =
                    derive_wire_label(circuit_id, instance_id, gate.wire_c, out_bit, seed);

                // Row encryption: ct = outLabel XOR pad(rowKey(...)).
                let row_key = compute_row_key(
                    circuit_id,
                    instance_id,
                    gate_index,
                    perm_a,
                    perm_b,
                    label_a,
                    label_b,
                );
                let pad = expand_pad(row_key);
                let ct = xor16(out_label, pad);

                // Solidity row order contract.
                let row_index = (2 * perm_a + perm_b) as usize;
                rows[row_index] = ct;
            }
        }
    } else {
        // Canonical NOT: rows stay all-zero; only gate header is meaningful.
    }

    encode_leaf(gate, rows)
}

/// Garbles a full circuit in gate-index order and returns all gate leaves.
pub fn garble_circuit(seed: [u8; 32], layout: &CircuitLayout) -> Vec<[u8; 71]> {
    // Index in iteration is part of consensus (`gateIndex` in hashing rules).
    layout
        .gates
        .iter()
        .enumerate()
        .map(|(idx, gate)| {
            recompute_gate_leaf(
                seed,
                layout.circuit_id,
                layout.instance_id,
                idx as u64,
                *gate,
            )
        })
        .collect()
}
