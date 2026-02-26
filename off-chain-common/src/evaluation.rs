use crate::consensus::{compute_row_key, derive_wire_label, expand_pad, xor16};
use crate::types::{CircuitLayout, GateDesc, GateType};

/// Auxiliary material for evaluating canonical `NOT` gates whose rows are zeroed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotGateHint {
    pub gate_index: usize,
    pub in_label0: [u8; 16],
    pub out_if_in0: [u8; 16], // semantic: 0 -> 1
    pub in_label1: [u8; 16],
    pub out_if_in1: [u8; 16], // semantic: 1 -> 0
}

/// Converts a 16-byte wire label to `bytes32` representation used by `settle(bytes32)`.
/// Layout: first 16 bytes are the wire label, remaining 16 bytes are zeros.
pub fn label16_to_bytes32(label: [u8; 16]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[..16].copy_from_slice(&label);
    out
}

/// Little-endian bit decomposition: bit 0 is LSB and maps to wire 0.
pub fn u64_to_bits_le(value: u64, bit_width: usize) -> Vec<u8> {
    (0..bit_width).map(|idx| ((value >> idx) & 1) as u8).collect()
}

/// Returns output wire id for a layout (the last gate output in this MVP circuit format).
pub fn output_wire_from_layout(gates: &[GateDesc]) -> Result<u16, String> {
    gates
        .last()
        .map(|g| g.wire_c)
        .ok_or_else(|| "layout has no gates".to_string())
}

/// Returns the `x > y` output wire for `build_millionaires_layout(bit_width)`.
/// Layout invariant:
/// - `bit_width == 1`: output is the last gate (single `a & !b`)
/// - `bit_width >= 2`: each following bit appends `gt_new` then `eq_new`,
///   so the final `gt_new` is the penultimate gate output.
pub fn millionaires_gt_output_wire(gates: &[GateDesc], bit_width: usize) -> Result<u16, String> {
    if gates.is_empty() {
        return Err("layout has no gates".to_string());
    }
    if bit_width == 1 {
        return Ok(gates[gates.len() - 1].wire_c);
    }
    if gates.len() < 2 {
        return Err("layout too short for bit_width >= 2".to_string());
    }
    Ok(gates[gates.len() - 2].wire_c)
}

/// Derives labels for Bob's input wires (`bit_width .. 2*bit_width-1`) for one instance.
pub fn derive_bob_label_offers(
    seed: [u8; 32],
    circuit_id: [u8; 32],
    instance_id: u64,
    bit_width: usize,
) -> Vec<([u8; 16], [u8; 16])> {
    (0..bit_width)
        .map(|bit_idx| {
            let wire = (bit_width + bit_idx) as u16;
            let l0 = derive_wire_label(circuit_id, instance_id, wire, 0, seed);
            let l1 = derive_wire_label(circuit_id, instance_id, wire, 1, seed);
            (l0, l1)
        })
        .collect()
}

/// Derives labels for Alice's input wires (`0 .. bit_width-1`) for one instance and value `x`.
pub fn derive_alice_input_labels(
    seed: [u8; 32],
    circuit_id: [u8; 32],
    instance_id: u64,
    bit_width: usize,
    x_value: u64,
) -> Vec<[u8; 16]> {
    let bits = u64_to_bits_le(x_value, bit_width);
    bits
        .iter()
        .enumerate()
        .map(|(bit_idx, bit)| {
            derive_wire_label(circuit_id, instance_id, bit_idx as u16, *bit, seed)
        })
        .collect()
}

/// Derives output labels (semantic 0 and semantic 1) for one layout instance.
pub fn derive_output_labels(
    seed: [u8; 32],
    layout: &CircuitLayout,
    output_wire: u16,
) -> Result<([u8; 16], [u8; 16]), String> {
    let l0 = derive_wire_label(layout.circuit_id, layout.instance_id, output_wire, 0, seed);
    let l1 = derive_wire_label(layout.circuit_id, layout.instance_id, output_wire, 1, seed);
    Ok((l0, l1))
}

/// Derives per-NOT-gate hints required for evaluation when NOT rows are canonical zeros.
pub fn derive_not_gate_hints(seed: [u8; 32], layout: &CircuitLayout) -> Vec<NotGateHint> {
    layout
        .gates
        .iter()
        .enumerate()
        .filter_map(|(gate_index, gate)| {
            if gate.gate_type != GateType::Not {
                return None;
            }

            let in0 = derive_wire_label(layout.circuit_id, layout.instance_id, gate.wire_a, 0, seed);
            let in1 = derive_wire_label(layout.circuit_id, layout.instance_id, gate.wire_a, 1, seed);
            let out_if_in0 =
                derive_wire_label(layout.circuit_id, layout.instance_id, gate.wire_c, 1, seed);
            let out_if_in1 =
                derive_wire_label(layout.circuit_id, layout.instance_id, gate.wire_c, 0, seed);
            Some(NotGateHint {
                gate_index,
                in_label0: in0,
                out_if_in0,
                in_label1: in1,
                out_if_in1,
            })
        })
        .collect()
}

fn row_ct_from_leaf(leaf: &[u8; 71], row_index: usize) -> Result<[u8; 16], String> {
    if row_index > 3 {
        return Err(format!("row index out of range: {row_index}"));
    }
    let start = 7 + 16 * row_index;
    let end = start + 16;
    let mut out = [0u8; 16];
    out.copy_from_slice(&leaf[start..end]);
    Ok(out)
}

/// Evaluates one garbled circuit instance from:
/// - full leaf list for that instance (`leaves`),
/// - Alice labels for x wires,
/// - Bob-selected labels for y wires,
/// - NOT hints.
pub fn evaluate_garbled_circuit(
    layout: &CircuitLayout,
    leaves: &[[u8; 71]],
    alice_input_labels: &[[u8; 16]],
    bob_input_labels: &[[u8; 16]],
    not_hints: &[NotGateHint],
    output_wire: u16,
) -> Result<[u8; 16], String> {
    let gates = &layout.gates;
    if leaves.len() != gates.len() {
        return Err(format!(
            "leaves count {} does not match gate count {}",
            leaves.len(),
            gates.len()
        ));
    }

    let bit_width = alice_input_labels.len();
    if bob_input_labels.len() != bit_width {
        return Err(format!(
            "bob input label count {} does not match alice count {}",
            bob_input_labels.len(),
            bit_width
        ));
    }

    let mut max_wire = (2 * bit_width).saturating_sub(1) as u16;
    for gate in gates {
        max_wire = max_wire.max(gate.wire_a).max(gate.wire_b).max(gate.wire_c);
    }
    let mut wire_labels = vec![None::<[u8; 16]>; max_wire as usize + 1];

    for (idx, label) in alice_input_labels.iter().enumerate() {
        wire_labels[idx] = Some(*label);
    }
    for (idx, label) in bob_input_labels.iter().enumerate() {
        wire_labels[bit_width + idx] = Some(*label);
    }

    for (gate_idx, gate) in gates.iter().enumerate() {
        let label_a = wire_labels[gate.wire_a as usize]
            .ok_or_else(|| format!("missing wire label for wireA={} gate={}", gate.wire_a, gate_idx))?;

        let out_label = match gate.gate_type {
            GateType::And | GateType::Xor => {
                let label_b = wire_labels[gate.wire_b as usize].ok_or_else(|| {
                    format!("missing wire label for wireB={} gate={}", gate.wire_b, gate_idx)
                })?;
                let perm_a = label_a[0] & 1;
                let perm_b = label_b[0] & 1;
                let row_index = (2 * perm_a + perm_b) as usize;
                let ct = row_ct_from_leaf(&leaves[gate_idx], row_index)?;

                let row_key = compute_row_key(
                    layout.circuit_id,
                    layout.instance_id,
                    gate_idx as u64,
                    perm_a,
                    perm_b,
                    label_a,
                    label_b,
                );
                let pad = expand_pad(row_key);
                xor16(ct, pad)
            }
            GateType::Not => {
                let hint = not_hints
                    .iter()
                    .find(|hint| hint.gate_index == gate_idx)
                    .ok_or_else(|| format!("missing NOT hint for gate={gate_idx}"))?;

                if label_a == hint.in_label0 {
                    hint.out_if_in0
                } else if label_a == hint.in_label1 {
                    hint.out_if_in1
                } else {
                    return Err(format!(
                        "NOT hint mismatch for gate={gate_idx}: input label is unknown to hint"
                    ));
                }
            }
        };

        wire_labels[gate.wire_c as usize] = Some(out_label);
    }

    if output_wire as usize >= wire_labels.len() {
        return Err(format!(
            "output wire {} is out of range (max={})",
            output_wire,
            wire_labels.len().saturating_sub(1)
        ));
    }
    wire_labels[output_wire as usize]
        .ok_or_else(|| format!("missing output wire label for wire={output_wire}"))
}
