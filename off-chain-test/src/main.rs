use off_chain_test::consensus::{keccak256, layout_leaf_hash};
use off_chain_test::garble::garble_circuit;
use off_chain_test::ih::{
    gc_block_hash, ih_proof_from_hashes, incremental_root_from_hashes, verify_ih_proof,
};
use off_chain_test::merkle::{merkle_proof_from_hashes, merkle_root_from_hashes, verify_proof};
use off_chain_test::scenario::{build_millionaires_layout, com_seed, derive_instance_seed, CUT_AND_CHOOSE_N};
use off_chain_test::types::{CircuitLayout, GateDesc, GateType};

/// Per-instance artifacts used to print Solidity-ready challenge data.
#[derive(Debug)]
struct InstanceArtifacts {
    instance_id: usize,
    seed: [u8; 32],
    com_seed: [u8; 32],
    root_gc: [u8; 32],
    leaves: Vec<[u8; 71]>,
    block_hashes: Vec<[u8; 32]>,
}

/// Parses `--flag value` or `--flag=value` as `usize`, falling back to `default`.
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

/// Hex-encodes bytes as `0x...`.
fn hex_prefixed(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Hex-encodes bytes without a prefix.
fn hex_plain(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Formats bytes as Solidity literal: `hex"..."`.
fn solidity_hex_literal(bytes: &[u8]) -> String {
    format!("hex\"{}\"", hex_plain(bytes))
}

/// Hex-encodes a `bytes32`.
fn hex32(value: [u8; 32]) -> String {
    hex_prefixed(&value)
}

/// Formats `bytes32[]` for direct copy-paste into Solidity tests.
fn hex_bytes32_vec(values: &[[u8; 32]]) -> String {
    let parts = values.iter().map(|v| hex32(*v)).collect::<Vec<_>>();
    format!("[{}]", parts.join(", "))
}

/// Solidity-friendly gate-type label used in generated snippet name/comments.
fn gate_type_label(g: GateType) -> &'static str {
    match g {
        GateType::And => "And",
        GateType::Xor => "Xor",
        GateType::Not => "Not",
    }
}

/// CLI entrypoint that generates:
/// - phase-2 commitments for `N=10`,
/// - phase-4 openings (`N-1` seeds),
/// - one `challengeGateLeaf` packet (leaf + proofs) for a selected gate.
#[tokio::main]
async fn main() {
    // CLI knobs for reproducible vector generation.
    let args: Vec<String> = std::env::args().collect();
    let bit_width = parse_usize_arg(&args, "--bits", 8);
    let m = parse_usize_arg(&args, "--m", 7);
    let gate_index = parse_usize_arg(&args, "--gate-index", 3);
    let challenge_instance_arg = parse_usize_arg(&args, "--challenge-instance", usize::MAX);

    let n = CUT_AND_CHOOSE_N;
    assert!(m < n, "m must be in [0, N)");

    let circuit_id = keccak256(&[b"millionaires-yao-v1"]);
    let master_seed = keccak256(&[b"master-seed-v1"]);
    // Deterministic layout so Solidity/Rust vectors are stable across runs.
    let gates = build_millionaires_layout(bit_width);
    assert!(
        gate_index < gates.len(),
        "gate_index={} out of range; layout has {} gates",
        gate_index,
        gates.len()
    );

    // Build layout commitment and inclusion proof for the challenged gate.
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
            // One full GC table (all leaves) per instance.
            let leaves = garble_circuit(seed, &layout);
            let block_hashes: Vec<[u8; 32]> = leaves
                .iter()
                .enumerate()
                .map(|(gate_idx, leaf)| gc_block_hash(gate_idx as u64, leaf))
                .collect();
            let root_gc = incremental_root_from_hashes(&block_hashes);
            InstanceArtifacts {
                instance_id,
                seed,
                com_seed: com_seed(seed),
                root_gc,
                leaves,
                block_hashes,
            }
        })
        .collect();

    // Open set is all indices except evaluation instance m.
    let open_indices: Vec<usize> = (0..n).filter(|idx| *idx != m).collect();
    let challenge_instance = if challenge_instance_arg == usize::MAX {
        // Default to first opened instance for challenge packet.
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
    let block_hash_value = inst.block_hashes[gate_index];
    let ih_proof = ih_proof_from_hashes(&inst.block_hashes, gate_index);
    let layout_leaf = layout_leaf_hash(gate_index as u64, gate);

    // Quick local verification before user copies values to Solidity tests.
    let proof_ok = verify_ih_proof(block_hash_value, &ih_proof, inst.root_gc);
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
    // `rootXG`, `rootOT`, `h0`, `h1` are placeholders in this MVP printer.
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
    println!("leafHash = {}", hex32(block_hash_value));
    println!("rootGC[instanceId] = {}", hex32(inst.root_gc));
    println!("ihProof = {}", hex_bytes32_vec(&ih_proof));
    println!("layoutLeaf = {}", hex32(layout_leaf));
    println!("layoutProof = {}", hex_bytes32_vec(&layout_proof));
    println!("circuitLayoutRoot = {}", hex32(circuit_layout_root));
    println!();

    println!("=== Proof Sanity ===");
    println!("gcIhProofValid = {}", proof_ok);
    println!("layoutProofValid = {}", layout_proof_ok);

    // Direct copy-paste helper for Solidity tests.
    let fn_name = format!("_rustVectorDefault{}Gate{}", gate_type_label(gate.gate_type), gate_index);
    println!();
    println!("=== Solidity Paste Snippet ===");
    println!("function {}() internal pure returns (RustGateChallengeVector memory v) {{", fn_name);
    println!("    v.circuitId = {};", solidity_hex_literal(&circuit_id));
    println!("    v.circuitLayoutRoot = {};", solidity_hex_literal(&circuit_layout_root));
    println!();
    println!("    v.mChoice = {};", m);
    println!("    v.challengeInstanceId = {};", challenge_instance);
    println!("    v.gateIndex = {};", gate_index);
    println!(
        "    v.gateType = {}; // {}",
        gate.gate_type as u8,
        gate_type_label(gate.gate_type).to_uppercase()
    );
    println!("    v.wireA = {};", gate.wire_a);
    println!("    v.wireB = {};", gate.wire_b);
    println!("    v.wireC = {};", gate.wire_c);
    println!("    v.expectMatch = true;");
    println!();
    println!("    v.leafBytes = {};", solidity_hex_literal(&leaf));
    println!();

    println!("    v.comSeeds = new bytes32[]({});", instances.len());
    for a in &instances {
        println!(
            "    v.comSeeds[{}] = {};",
            a.instance_id,
            solidity_hex_literal(&a.com_seed)
        );
    }
    println!();

    println!("    v.rootGCs = new bytes32[]({});", instances.len());
    for a in &instances {
        println!(
            "    v.rootGCs[{}] = {};",
            a.instance_id,
            solidity_hex_literal(&a.root_gc)
        );
    }
    println!();

    println!("    v.openIndices = new uint256[]({});", open_indices.len());
    for (i, idx) in open_indices.iter().enumerate() {
        println!("    v.openIndices[{}] = {};", i, idx);
    }
    println!();

    println!("    v.openSeeds = new bytes32[]({});", open_indices.len());
    for (i, idx) in open_indices.iter().enumerate() {
        println!(
            "    v.openSeeds[{}] = {};",
            i,
            solidity_hex_literal(&instances[*idx].seed)
        );
    }
    println!();

    println!("    v.ihProof = new bytes32[]({});", ih_proof.len());
    for (i, hash) in ih_proof.iter().enumerate() {
        println!("    v.ihProof[{}] = {};", i, solidity_hex_literal(hash));
    }
    println!();

    println!("    v.layoutProof = new bytes32[]({});", layout_proof.len());
    for (i, hash) in layout_proof.iter().enumerate() {
        println!("    v.layoutProof[{}] = {};", i, solidity_hex_literal(hash));
    }
    println!("}}");
}
