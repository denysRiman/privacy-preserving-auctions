use crate::consensus::{keccak256, uint256_from_u64};
use crate::types::{GateDesc, GateType};

/// Number of circuit instances used in cut-and-choose for this MVP flow.
pub const CUT_AND_CHOOSE_N: usize = 10;

/// Internal helper: append one gate and allocate a fresh output wire.
fn push_gate(gates: &mut Vec<GateDesc>, next_wire: &mut u16, gate_type: GateType, a: u16, b: u16) -> u16 {
    let out = *next_wire;
    // New gate writes into the next free wire index.
    gates.push(GateDesc::new(gate_type, a, b, out));
    *next_wire = next_wire.saturating_add(1);
    out
}

/// Internal helper for XOR gate creation.
fn push_xor(gates: &mut Vec<GateDesc>, next_wire: &mut u16, a: u16, b: u16) -> u16 {
    push_gate(gates, next_wire, GateType::Xor, a, b)
}

/// Internal helper for AND gate creation.
fn push_and(gates: &mut Vec<GateDesc>, next_wire: &mut u16, a: u16, b: u16) -> u16 {
    push_gate(gates, next_wire, GateType::And, a, b)
}

/// Internal helper for NOT gate creation.
fn push_not(gates: &mut Vec<GateDesc>, next_wire: &mut u16, a: u16) -> u16 {
    push_gate(gates, next_wire, GateType::Not, a, 0)
}

/// Internal OR helper implemented as `(a XOR b) XOR (a AND b)`.
fn push_or(gates: &mut Vec<GateDesc>, next_wire: &mut u16, a: u16, b: u16) -> u16 {
    let xor_ab = push_xor(gates, next_wire, a, b);
    let and_ab = push_and(gates, next_wire, a, b);
    push_xor(gates, next_wire, xor_ab, and_ab)
}

/// Builds a deterministic Millionaires-comparison circuit layout for `bit_width`-bit inputs.
/// Input wire convention:
/// - Alice bits: `[0 .. bit_width-1]`
/// - Bob bits: `[bit_width .. 2*bit_width-1]`
pub fn build_millionaires_layout(bit_width: usize) -> Vec<GateDesc> {
    assert!(bit_width > 0, "bit_width must be > 0");
    assert!(bit_width <= (u16::MAX as usize) / 4, "bit_width too large");

    let mut gates = Vec::new();
    // Reserve input wires first: A bits then B bits.
    let mut next_wire = (bit_width * 2) as u16;

    // Running accumulators for:
    // - gt_acc: "A > B already seen at higher bit"
    // - eq_acc: "A == B for all higher bits"
    let mut gt_acc: Option<u16> = None;
    let mut eq_acc: Option<u16> = None;

    // Compare from MSB to LSB.
    for bit in (0..bit_width).rev() {
        let a = bit as u16;
        let b = (bit + bit_width) as u16;

        // eq_bit = !(a XOR b)
        let xor_ab = push_xor(&mut gates, &mut next_wire, a, b);
        let eq_bit = push_not(&mut gates, &mut next_wire, xor_ab);

        // gt_bit = a AND (!b)
        let not_b = push_not(&mut gates, &mut next_wire, b);
        let gt_bit = push_and(&mut gates, &mut next_wire, a, not_b);

        match (gt_acc, eq_acc) {
            (None, None) => {
                // Highest bit initializes accumulators.
                gt_acc = Some(gt_bit);
                eq_acc = Some(eq_bit);
            }
            (Some(gt_prev), Some(eq_prev)) => {
                // gt_new = gt_prev OR (eq_prev AND gt_bit)
                let eq_and_gt = push_and(&mut gates, &mut next_wire, eq_prev, gt_bit);
                let gt_new = push_or(&mut gates, &mut next_wire, gt_prev, eq_and_gt);
                // eq_new = eq_prev AND eq_bit
                let eq_new = push_and(&mut gates, &mut next_wire, eq_prev, eq_bit);
                gt_acc = Some(gt_new);
                eq_acc = Some(eq_new);
            }
            _ => unreachable!("accumulators must progress together"),
        }
    }

    gates
}

/// Derives one per-instance seed from a master seed and circuit context.
/// Domain separation uses `"SEED"`.
pub fn derive_instance_seed(master_seed: [u8; 32], circuit_id: [u8; 32], instance_id: u64) -> [u8; 32] {
    let instance = uint256_from_u64(instance_id);
    keccak256(&[b"SEED", &circuit_id, &instance, &master_seed])
}

/// Computes phase-2 seed commitment (`comSeed`) as Solidity `keccak256(abi.encodePacked(seed))`.
pub fn com_seed(seed: [u8; 32]) -> [u8; 32] {
    keccak256(&[&seed])
}
