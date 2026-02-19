use off_chain::consensus::{keccak256, layout_leaf_hash};
use off_chain::garble::garble_circuit;
use off_chain::merkle::{leaf_hash, merkle_proof_from_hashes, merkle_root_from_hashes, verify_proof};
use off_chain::scenario::{build_millionaires_layout, com_seed, derive_instance_seed, CUT_AND_CHOOSE_N};
use off_chain::types::{CircuitLayout, GateDesc};

#[derive(Debug)]
struct InstanceArtifacts {
    instance_id: usize,
    seed: [u8; 32],
    com_seed: [u8; 32],
    root_gc: [u8; 32],
    leaves: Vec<[u8; 71]>,
    leaf_hashes: Vec<[u8; 32]>,
}

fn parse_usize_arg(args: &[String], flag: &str, default: usize) -> usize {
    let key_eq = format!("{flag}=");
    let mut idx = 0usize;
    while idx < args.len() {
        if args[idx] == flag {
            if idx + 1 < args.len() {
                return args[idx + 1].parse::<usize>().unwrap_or(default);
            }
            return default;
        }
        if let Some(raw) = args[idx].strip_prefix(&key_eq) {
            return raw.parse::<usize>().unwrap_or(default);
        }
        idx += 1;
    }
    default
}

fn hex_prefixed(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn hex32(value: [u8; 32]) -> String {
    hex_prefixed(&value)
}

fn hex_bytes32_vec(values: &[[u8; 32]]) -> String {
    let parts = values.iter().map(|v| hex32(*v)).collect::<Vec<_>>();
    format!("[{}]", parts.join(", "))
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bit_width = parse_usize_arg(&args, "--bits", 8);
    let m = parse_usize_arg(&args, "--m", 7);
    let gate_index = parse_usize_arg(&args, "--gate-index", 3);
    let challenge_instance_arg = parse_usize_arg(&args, "--challenge-instance", usize::MAX);

    let n = CUT_AND_CHOOSE_N;
    assert!(m < n, "m must be in [0, N)");

    let circuit_id = keccak256(&[b"millionaires-yao-v1"]);
    let master_seed = keccak256(&[b"master-seed-v1"]);
    let gates = build_millionaires_layout(bit_width);
    assert!(
        gate_index < gates.len(),
        "gate_index={} out of range; layout has {} gates",
        gate_index,
        gates.len()
    );

    let layout_leaf_hashes: Vec<[u8; 32]> = gates
        .iter()
        .enumerate()
        .map(|(idx, gate)| layout_leaf_hash(idx as u64, *gate))
        .collect();
    let circuit_layout_root = merkle_root_from_hashes(&layout_leaf_hashes);
    let layout_proof = merkle_proof_from_hashes(&layout_leaf_hashes, gate_index);

    let instances: Vec<InstanceArtifacts> = (0..n)
        .map(|instance_id| {
            let seed = derive_instance_seed(master_seed, circuit_id, instance_id as u64);
            let layout = CircuitLayout {
                circuit_id,
                instance_id: instance_id as u64,
                gates: gates.clone(),
            };
            let leaves = garble_circuit(seed, &layout);
            let leaf_hashes: Vec<[u8; 32]> = leaves.iter().map(|leaf| leaf_hash(leaf)).collect();
            let root_gc = merkle_root_from_hashes(&leaf_hashes);
            InstanceArtifacts {
                instance_id,
                seed,
                com_seed: com_seed(seed),
                root_gc,
                leaves,
                leaf_hashes,
            }
        })
        .collect();

    let open_indices: Vec<usize> = (0..n).filter(|idx| *idx != m).collect();
    let challenge_instance = if challenge_instance_arg == usize::MAX {
        open_indices[0]
    } else {
        challenge_instance_arg
    };
    assert!(challenge_instance < n, "challenge-instance must be in [0, N)");
    assert!(
        challenge_instance != m,
        "challenge-instance must be in opened set (cannot be m)"
    );

    let inst = &instances[challenge_instance];
    let gate: GateDesc = gates[gate_index];
    let leaf = inst.leaves[gate_index];
    let leaf_hash_value = inst.leaf_hashes[gate_index];
    let merkle_proof = merkle_proof_from_hashes(&inst.leaf_hashes, gate_index);
    let layout_leaf = layout_leaf_hash(gate_index as u64, gate);

    let proof_ok = verify_proof(leaf_hash_value, &merkle_proof, inst.root_gc);
    let layout_proof_ok = verify_proof(layout_leaf, &layout_proof, circuit_layout_root);

    println!("=== Cut-and-Choose Snapshot ===");
    println!("N = {}", n);
    println!("bitWidth = {}", bit_width);
    println!("gateCount = {}", gates.len());
    println!("evaluation m = {}", m);
    println!("challenge instance = {}", challenge_instance);
    println!("gateIndex = {}", gate_index);
    println!("circuitId = {}", hex32(circuit_id));
    println!("masterSeed = {}", hex32(master_seed));
    println!("circuitLayoutRoot = {}", hex32(circuit_layout_root));
    println!();

    println!("=== Phase-2 Commitments (submitCommitments) ===");
    let zero32 = [0u8; 32];
    for a in &instances {
        println!(
            "instance[{}]: comSeed={} rootGC={} rootXG={} rootOT={} h0={} h1={}",
            a.instance_id,
            hex32(a.com_seed),
            hex32(a.root_gc),
            hex32(zero32),
            hex32(zero32),
            hex32(zero32),
            hex32(zero32)
        );
    }
    println!();

    println!("=== Phase-4 Openings (revealOpenings) ===");
    println!("indices = {:?}", open_indices);
    for idx in &open_indices {
        println!("seed[{}] = {}", idx, hex32(instances[*idx].seed));
    }
    println!();

    println!("=== Solidity Challenge Packet (challengeGateLeaf) ===");
    println!("instanceId = {}", challenge_instance);
    println!("gateIndex = {}", gate_index);
    println!("g.gateType = {}", gate.gate_type as u8);
    println!("g.wireA = {}", gate.wire_a);
    println!("g.wireB = {}", gate.wire_b);
    println!("g.wireC = {}", gate.wire_c);
    println!("leafBytes = {}", hex_prefixed(&leaf));
    println!("leafHash = {}", hex32(leaf_hash_value));
    println!("rootGC[instanceId] = {}", hex32(inst.root_gc));
    println!("merkleProof = {}", hex_bytes32_vec(&merkle_proof));
    println!("layoutLeaf = {}", hex32(layout_leaf));
    println!("layoutProof = {}", hex_bytes32_vec(&layout_proof));
    println!("circuitLayoutRoot = {}", hex32(circuit_layout_root));
    println!();

    println!("=== Proof Sanity ===");
    println!("gcProofValid = {}", proof_ok);
    println!("layoutProofValid = {}", layout_proof_ok);
}
