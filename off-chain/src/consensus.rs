use sha3::{Digest, Keccak256};

use crate::types::{GateDesc, GateType};

/// Packed gate-leaf length used by Solidity (`1 + 2 + 2 + 2 + 4*16`).
pub const LEAF_BYTES_LEN: usize = 71;

/// Computes `keccak256` over concatenated byte slices, equivalent to `abi.encodePacked(...)`.
pub fn keccak256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    for part in parts {
        // Equivalent to appending bytes in `abi.encodePacked(...)`.
        hasher.update(part);
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&hasher.finalize());
    out
}

/// Encodes a Rust `u64` into Solidity `uint256` big-endian bytes.
pub fn uint256_from_u64(value: u64) -> [u8; 32] {
    let mut out = [0u8; 32];
    // Place the 8-byte value in the least-significant slot of uint256.
    out[24..].copy_from_slice(&value.to_be_bytes());
    out
}

/// Mirrors Solidity `computeWireFlipBit`:
/// `keccak256("P", circuitId, instanceId, wireId, seed) & 1`.
pub fn derive_wire_flip_bit(
    circuit_id: [u8; 32],
    instance_id: u64,
    wire_id: u16,
    seed: [u8; 32],
) -> u8 {
    let instance = uint256_from_u64(instance_id);
    // Domain "P" separates point-and-permute randomness from other hashes.
    let h = keccak256(&[b"P", &circuit_id, &instance, &wire_id.to_be_bytes(), &seed]);
    h[31] & 1
}

/// Mirrors Solidity `deriveWireLabel`:
/// first 16 bytes of `keccak256("L", ...)` with first-byte LSB rewritten to `flip XOR semantic`.
pub fn derive_wire_label(
    circuit_id: [u8; 32],
    instance_id: u64,
    wire_id: u16,
    semantic_bit: u8,
    seed: [u8; 32],
) -> [u8; 16] {
    let instance = uint256_from_u64(instance_id);
    let bit = [semantic_bit & 1];
    // Base label body comes from domain "L".
    let h = keccak256(&[
        b"L",
        &circuit_id,
        &instance,
        &wire_id.to_be_bytes(),
        &bit,
        &seed,
    ]);

    let mut label = [0u8; 16];
    label.copy_from_slice(&h[..16]);

    // Force first-byte LSB to permutation bit as in Solidity.
    let flip = derive_wire_flip_bit(circuit_id, instance_id, wire_id, seed);
    let permute = (flip ^ (semantic_bit & 1)) & 1;
    label[0] = (label[0] & 0xFE) | permute;
    label
}

/// Mirrors Solidity `computeRowKey`:
/// `keccak256("K", circuitId, instanceId, gateIndex, permA, permB, labelA, labelB)`.
pub fn compute_row_key(
    circuit_id: [u8; 32],
    instance_id: u64,
    gate_index: u64,
    perm_a: u8,
    perm_b: u8,
    label_a: [u8; 16],
    label_b: [u8; 16],
) -> [u8; 32] {
    let instance = uint256_from_u64(instance_id);
    let gate = uint256_from_u64(gate_index);
    // `perm_a` and `perm_b` are serialized as packed uint8 values.
    let pa = [perm_a & 1];
    let pb = [perm_b & 1];
    keccak256(&[
        b"K",
        &circuit_id,
        &instance,
        &gate,
        &pa,
        &pb,
        &label_a,
        &label_b,
    ])
}

/// Mirrors Solidity `expandPad`: first 16 bytes of `keccak256("PAD", rowKey)`.
pub fn expand_pad(row_key: [u8; 32]) -> [u8; 16] {
    let h = keccak256(&[b"PAD", &row_key]);
    let mut out = [0u8; 16];
    out.copy_from_slice(&h[..16]);
    out
}

/// XOR helper for 16-byte labels/pads.
pub fn xor16(a: [u8; 16], b: [u8; 16]) -> [u8; 16] {
    let mut out = [0u8; 16];
    for i in 0..16 {
        out[i] = a[i] ^ b[i];
    }
    out
}

/// Encodes a gate leaf exactly as Solidity expects:
/// `gateType || wireA || wireB || wireC || row0 || row1 || row2 || row3`.
pub fn encode_leaf(gate: GateDesc, rows: [[u8; 16]; 4]) -> [u8; LEAF_BYTES_LEN] {
    let mut out = [0u8; LEAF_BYTES_LEN];
    // Gate header: opcode + wire indices.
    out[0] = gate.gate_type as u8;
    out[1..3].copy_from_slice(&gate.wire_a.to_be_bytes());
    out[3..5].copy_from_slice(&gate.wire_b.to_be_bytes());
    out[5..7].copy_from_slice(&gate.wire_c.to_be_bytes());

    // Rows are always serialized in fixed order: row0, row1, row2, row3.
    let mut cursor = 7;
    for row in rows {
        out[cursor..cursor + 16].copy_from_slice(&row);
        cursor += 16;
    }
    out
}

/// Mirrors Solidity `_layoutLeafHash`:
/// `keccak256(gateIndex, gateType, wireA, wireB, wireC)`.
pub fn layout_leaf_hash(gate_index: u64, gate: GateDesc) -> [u8; 32] {
    let gate_idx = uint256_from_u64(gate_index);
    let t = [gate.gate_type as u8];
    keccak256(&[
        &gate_idx,
        &t,
        &gate.wire_a.to_be_bytes(),
        &gate.wire_b.to_be_bytes(),
        &gate.wire_c.to_be_bytes(),
    ])
}

/// Gate truth table used during row generation.
/// `Not` returns `0` because NOT rows are canonicalized to zero in this flow.
pub fn truth_table(gate_type: GateType, a: u8, b: u8) -> u8 {
    match gate_type {
        GateType::And => (a & b) & 1,
        GateType::Xor => (a ^ b) & 1,
        // NOT does not use row table in this canonical format.
        GateType::Not => 0,
    }
}
