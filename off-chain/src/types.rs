#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum GateType {
    And = 0,
    Xor = 1,
    Not = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GateDesc {
    pub gate_type: GateType,
    pub wire_a: u16,
    pub wire_b: u16,
    pub wire_c: u16,
}

impl GateDesc {
    pub fn new(gate_type: GateType, wire_a: u16, wire_b: u16, wire_c: u16) -> Self {
        Self {
            gate_type,
            wire_a,
            wire_b,
            wire_c,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CircuitLayout {
    pub circuit_id: [u8; 32],
    pub instance_id: u64,
    pub gates: Vec<GateDesc>,
}
