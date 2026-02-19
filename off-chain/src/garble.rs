use crate::consensus::{
    compute_row_key, derive_wire_flip_bit, derive_wire_label, encode_leaf, expand_pad, truth_table,
    xor16,
};
use crate::types::{CircuitLayout, GateDesc, GateType};

pub fn recompute_gate_leaf(
    seed: [u8; 32],
    circuit_id: [u8; 32],
    instance_id: u64,
    gate_index: u64,
    gate: GateDesc,
) -> [u8; 71] {
    let mut rows = [[0u8; 16]; 4];

    if gate.gate_type != GateType::Not {
        let flip_a = derive_wire_flip_bit(circuit_id, instance_id, gate.wire_a, seed);
        let flip_b = derive_wire_flip_bit(circuit_id, instance_id, gate.wire_b, seed);

        for perm_a in 0..=1 {
            for perm_b in 0..=1 {
                let bit_a = perm_a ^ flip_a;
                let bit_b = perm_b ^ flip_b;
                let out_bit = truth_table(gate.gate_type, bit_a, bit_b);

                let label_a = derive_wire_label(circuit_id, instance_id, gate.wire_a, bit_a, seed);
                let label_b = derive_wire_label(circuit_id, instance_id, gate.wire_b, bit_b, seed);
                let out_label =
                    derive_wire_label(circuit_id, instance_id, gate.wire_c, out_bit, seed);

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

                let row_index = (2 * perm_a + perm_b) as usize;
                rows[row_index] = ct;
            }
        }
    }

    encode_leaf(gate, rows)
}

pub fn garble_circuit(seed: [u8; 32], layout: &CircuitLayout) -> Vec<[u8; 71]> {
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
