/// Supported gate opcodes; numeric values match Solidity `GateType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum GateType {
    And = 0,
    Xor = 1,
    Not = 2,
}

/// One gate descriptor from circuit layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GateDesc {
    /// Gate opcode (`AND`, `XOR`, `NOT`).
    pub gate_type: GateType,
    /// Left input wire index.
    pub wire_a: u16,
    /// Right input wire index (`0` for canonical `NOT`).
    pub wire_b: u16,
    /// Output wire index.
    pub wire_c: u16,
}

impl GateDesc {
    /// Convenience constructor for a layout gate.
    pub fn new(gate_type: GateType, wire_a: u16, wire_b: u16, wire_c: u16) -> Self {
        Self {
            gate_type,
            wire_a,
            wire_b,
            wire_c,
        }
    }
}

/// Full circuit description passed into the garbler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CircuitLayout {
    /// Circuit identifier used in all domain-separated hashes.
    pub circuit_id: [u8; 32],
    /// Cut-and-choose instance index (`0..N-1`).
    pub instance_id: u64,
    /// Ordered gate list; position in this vector is the `gateIndex`.
    pub gates: Vec<GateDesc>,
}
