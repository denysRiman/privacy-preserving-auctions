use off_chain_test::consensus::{keccak256, layout_leaf_hash};
use off_chain_test::garble::garble_circuit;
use off_chain_test::ih::{gc_block_hash, ih_proof_from_hashes, incremental_root_from_hashes};
use off_chain_test::merkle::{merkle_proof_from_hashes, merkle_root_from_hashes};
use off_chain_test::scenario::build_millionaires_layout;
use off_chain_test::types::{CircuitLayout, GateDesc};
use std::env;
use std::error::Error;
use std::fs;
use std::path::Path;
use std::process::Command;

type AppResult<T> = Result<T, Box<dyn Error>>;

#[derive(Debug, Clone)]
struct PrepareDisputeConfig {
    bit_width: usize,
    circuit_id: [u8; 32],
    instance_id: u64,
    seed: [u8; 32],
    claimed_leaves: Vec<[u8; 71]>,
    gate_index: Option<usize>,
    allow_false_challenge: bool,
    expected_root_gc: Option<[u8; 32]>,
}

#[derive(Debug, Clone)]
struct PreparedDispute {
    gate_index: usize,
    gate: GateDesc,
    claimed_leaf: [u8; 71],
    expected_leaf: [u8; 71],
    mismatch_indices: Vec<usize>,
    root_gc: [u8; 32],
    layout_root: [u8; 32],
    ih_proof: Vec<[u8; 32]>,
    layout_proof: Vec<[u8; 32]>,
}

fn required_env(name: &str) -> AppResult<String> {
    env::var(name).map_err(|_| format!("Missing required env var: {name}").into())
}

fn env_truthy(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => {
            let normalized = value.trim().to_ascii_lowercase();
            matches!(normalized.as_str(), "1" | "true" | "yes" | "on")
        }
        Err(_) => false,
    }
}

fn cast_args_with_tx_overrides(args: &[String]) -> Vec<String> {
    let mut out = args.to_vec();
    if out.first().map(String::as_str) != Some("send") {
        return out;
    }

    if env_truthy("TX_LEGACY") && !out.iter().any(|arg| arg == "--legacy") {
        out.push("--legacy".to_string());
    }

    if !out.iter().any(|arg| arg == "--gas-price") {
        if let Ok(gas_price_wei) = env::var("TX_GAS_PRICE_WEI") {
            let trimmed = gas_price_wei.trim();
            if !trimmed.is_empty() {
                out.push("--gas-price".to_string());
                out.push(trimmed.to_string());
            }
        }
    }

    out
}

fn run_cast(args: &[String]) -> AppResult<String> {
    let final_args = cast_args_with_tx_overrides(args);
    let output = Command::new("cast").args(&final_args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("cast {} failed: {}", final_args.join(" "), stderr.trim()).into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn cast_output_field(output: &str, key: &str) -> Option<String> {
    for line in output.lines() {
        let mut parts = line.split_whitespace();
        if let Some(found_key) = parts.next() {
            if found_key == key {
                if let Some(value) = parts.next() {
                    return Some(value.to_string());
                }
            }
        }
    }
    None
}

fn print_tx_summary(label: &str, output: &str) {
    if let Some(tx_hash) = cast_output_field(output, "transactionHash") {
        println!("{label}_tx_hash={tx_hash}");
        return;
    }
    if let Some(status) = cast_output_field(output, "status") {
        println!("{label}_status={status}");
        return;
    }

    if let Some(first_line) = output.lines().next() {
        println!("{label}_tx={first_line}");
    } else {
        println!("{label}_tx=submitted");
    }
}

fn rpc_url() -> String {
    env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string())
}

fn hex_nibble(value: u8) -> AppResult<u8> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(10 + value - b'a'),
        b'A'..=b'F' => Ok(10 + value - b'A'),
        _ => Err(format!("invalid hex character: {}", value as char).into()),
    }
}

fn strip_0x(value: &str) -> &str {
    value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value)
}

fn decode_hex(value: &str) -> AppResult<Vec<u8>> {
    let raw = strip_0x(value.trim());
    if raw.len() % 2 != 0 {
        return Err(format!("hex length must be even: {value}").into());
    }

    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0usize;
    while i < bytes.len() {
        let hi = hex_nibble(bytes[i])?;
        let lo = hex_nibble(bytes[i + 1])?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn parse_bytes32(value: &str) -> AppResult<[u8; 32]> {
    let decoded = decode_hex(value)?;
    if decoded.len() != 32 {
        return Err(format!("expected 32 bytes, got {}", decoded.len()).into());
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&decoded);
    Ok(out)
}

fn parse_leaf71(value: &str) -> AppResult<[u8; 71]> {
    let decoded = decode_hex(value)?;
    if decoded.len() != 71 {
        return Err(format!("expected 71-byte leaf, got {}", decoded.len()).into());
    }
    let mut out = [0u8; 71];
    out.copy_from_slice(&decoded);
    Ok(out)
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

fn bytes32_vec_literal(values: &[[u8; 32]]) -> String {
    if values.is_empty() {
        return "[]".to_string();
    }
    let parts = values.iter().map(|v| hex32(*v)).collect::<Vec<_>>();
    format!("[{}]", parts.join(","))
}

fn parse_bytes32_list_csv(value: &str) -> AppResult<Vec<[u8; 32]>> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let normalized = trimmed
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim();
    if normalized.is_empty() {
        return Ok(Vec::new());
    }

    normalized
        .split(',')
        .map(|part| parse_bytes32(part.trim()))
        .collect()
}

fn parse_flag_value(args: &[String], flag: &str) -> Option<String> {
    let key_eq = format!("{flag}=");
    let mut idx = 0usize;
    while idx < args.len() {
        if args[idx] == flag {
            if idx + 1 < args.len() {
                return Some(args[idx + 1].clone());
            }
            return None;
        }
        if let Some(raw) = args[idx].strip_prefix(&key_eq) {
            return Some(raw.to_string());
        }
        idx += 1;
    }
    None
}

fn required_flag_value(args: &[String], flag: &str) -> AppResult<String> {
    parse_flag_value(args, flag)
        .ok_or_else(|| format!("Missing required argument: {flag}").into())
}

fn parse_u64(value: &str, name: &str) -> AppResult<u64> {
    value
        .parse::<u64>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

fn parse_u16(value: &str, name: &str) -> AppResult<u16> {
    value
        .parse::<u16>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

fn parse_u8(value: &str, name: &str) -> AppResult<u8> {
    value
        .parse::<u8>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

fn read_claimed_leaves_file(path: &Path) -> AppResult<Vec<[u8; 71]>> {
    let raw = fs::read_to_string(path)?;
    let mut leaves = Vec::new();

    for (line_idx, line) in raw.lines().enumerate() {
        let mut value = line
            .split('#')
            .next()
            .unwrap_or("")
            .trim()
            .trim_end_matches(',')
            .trim()
            .trim_matches('"')
            .trim();

        if value.is_empty() {
            continue;
        }

        // Allow a bracket-wrapped one-leaf-per-line format.
        value = value.trim_start_matches('[').trim_end_matches(']');
        if value.is_empty() {
            continue;
        }

        let leaf = parse_leaf71(value).map_err(|e| {
            format!(
                "invalid claimed leaf at {}:{}: {}",
                path.display(),
                line_idx + 1,
                e
            )
        })?;
        leaves.push(leaf);
    }

    if leaves.is_empty() {
        return Err(format!("No claimed leaves found in {}", path.display()).into());
    }
    Ok(leaves)
}

fn prepare_dispute_packet(config: &PrepareDisputeConfig) -> AppResult<PreparedDispute> {
    let gates = build_millionaires_layout(config.bit_width);
    if config.claimed_leaves.len() != gates.len() {
        return Err(format!(
            "claimed leaves count ({}) does not match circuit gate count ({})",
            config.claimed_leaves.len(),
            gates.len()
        )
        .into());
    }

    let layout = CircuitLayout {
        circuit_id: config.circuit_id,
        instance_id: config.instance_id,
        gates: gates.clone(),
    };

    let expected_leaves = garble_circuit(config.seed, &layout);
    let mismatch_indices = config
        .claimed_leaves
        .iter()
        .zip(expected_leaves.iter())
        .enumerate()
        .filter_map(|(idx, (claimed, expected))| {
            if claimed != expected {
                Some(idx)
            } else {
                None
            }
        })
        .collect::<Vec<_>>();

    if mismatch_indices.is_empty() && config.gate_index.is_none() {
        return Err(
            "No mismatches found between claimed and expected leaves; dispute packet not created"
                .into(),
        );
    }

    let selected_gate_index = config
        .gate_index
        .unwrap_or_else(|| mismatch_indices[0]);
    if selected_gate_index >= gates.len() {
        return Err(format!(
            "gate index {} out of range, total gates {}",
            selected_gate_index,
            gates.len()
        )
        .into());
    }

    let selected_is_mismatch = mismatch_indices.contains(&selected_gate_index);
    if !selected_is_mismatch && !config.allow_false_challenge {
        return Err(format!(
            "selected gate {} matches expected leaf; refusing false challenge (use --allow-false-challenge to override)",
            selected_gate_index
        )
        .into());
    }

    let block_hashes = config
        .claimed_leaves
        .iter()
        .enumerate()
        .map(|(idx, leaf)| gc_block_hash(idx as u64, leaf))
        .collect::<Vec<_>>();
    let root_gc = incremental_root_from_hashes(&block_hashes);
    if let Some(expected_root_gc) = config.expected_root_gc {
        if root_gc != expected_root_gc {
            return Err(format!(
                "computed rootGC {} does not match expected {}",
                hex32(root_gc),
                hex32(expected_root_gc)
            )
            .into());
        }
    }

    let ih_proof = ih_proof_from_hashes(&block_hashes, selected_gate_index);
    let layout_leaf_hashes = gates
        .iter()
        .enumerate()
        .map(|(idx, gate)| layout_leaf_hash(idx as u64, *gate))
        .collect::<Vec<_>>();
    let layout_root = merkle_root_from_hashes(&layout_leaf_hashes);
    let layout_proof = merkle_proof_from_hashes(&layout_leaf_hashes, selected_gate_index);

    Ok(PreparedDispute {
        gate_index: selected_gate_index,
        gate: gates[selected_gate_index],
        claimed_leaf: config.claimed_leaves[selected_gate_index],
        expected_leaf: expected_leaves[selected_gate_index],
        mismatch_indices,
        root_gc,
        layout_root,
        ih_proof,
        layout_proof,
    })
}

fn cmd_deposit() -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let bob_private_key = required_env("BOB_PRIVATE_KEY")?;
    let deposit_wei = env::var("DEPOSIT_WEI").unwrap_or_else(|_| "1000000000000000000".to_string());

    let stage_before = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "currentStage()(uint8)".to_string(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("stage_before={stage_before}");

    let configured_bob = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "bob()(address)".to_string(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    let signer_bob = run_cast(&[
        "wallet".to_string(),
        "address".to_string(),
        "--private-key".to_string(),
        bob_private_key.clone(),
    ])?;
    let wallet_before = run_cast(&[
        "balance".to_string(),
        signer_bob.clone(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("configured_bob={configured_bob}");
    println!("signer_bob={signer_bob}");
    println!("bob_wallet_before={wallet_before}");

    println!(
        "sending deposit() to {} with value={} wei",
        contract_address, deposit_wei
    );
    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address.clone(),
        "deposit()".to_string(),
        "--value".to_string(),
        deposit_wei,
        "--private-key".to_string(),
        bob_private_key,
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    print_tx_summary("deposit", &tx_result);
    let wallet_after = run_cast(&[
        "balance".to_string(),
        signer_bob.clone(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("bob_wallet_after={wallet_after}");

    let bob_vault = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "vault(address)(uint256)".to_string(),
        signer_bob,
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    let stage_after = run_cast(&[
        "call".to_string(),
        contract_address,
        "currentStage()(uint8)".to_string(),
        "--rpc-url".to_string(),
        rpc_url,
    ])?;
    println!("bob_vault={bob_vault}");
    println!("stage_after={stage_after}");

    Ok(())
}

fn cmd_choose(args: &[String]) -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let bob_private_key = required_env("BOB_PRIVATE_KEY")?;

    let m_raw = if let Some(value) = parse_flag_value(args, "--m") {
        value
    } else if let Some(first) = args.first() {
        first.clone()
    } else {
        return Err("Missing m index (use: choose --m <index>)".into());
    };
    let m = parse_u64(&m_raw, "m")?;

    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address,
        "choose(uint256)".to_string(),
        m.to_string(),
        "--private-key".to_string(),
        bob_private_key,
        "--rpc-url".to_string(),
        rpc_url,
    ])?;
    print_tx_summary("choose", &tx_result);
    Ok(())
}

fn cmd_prepare_dispute(args: &[String]) -> AppResult<()> {
    let bit_width = parse_flag_value(args, "--bit-width")
        .as_deref()
        .map(|v| parse_u64(v, "bit-width"))
        .transpose()?
        .unwrap_or(8) as usize;
    let instance_id = parse_u64(&required_flag_value(args, "--instance-id")?, "instance-id")?;
    let seed = parse_bytes32(&required_flag_value(args, "--seed")?)?;
    let leaves_file = required_flag_value(args, "--claimed-leaves-file")?;
    let gate_index = parse_flag_value(args, "--gate-index")
        .as_deref()
        .map(|v| parse_u64(v, "gate-index"))
        .transpose()?
        .map(|v| v as usize);
    let allow_false_challenge = args
        .iter()
        .any(|arg| arg == "--allow-false-challenge");
    let expected_root_gc = parse_flag_value(args, "--expected-root-gc")
        .as_deref()
        .map(parse_bytes32)
        .transpose()?;
    let circuit_id = parse_flag_value(args, "--circuit-id")
        .as_deref()
        .map(parse_bytes32)
        .transpose()?
        .unwrap_or_else(|| keccak256(&[b"millionaires-yao-v1"]));

    let claimed_leaves = read_claimed_leaves_file(Path::new(&leaves_file))?;
    let config = PrepareDisputeConfig {
        bit_width,
        circuit_id,
        instance_id,
        seed,
        claimed_leaves,
        gate_index,
        allow_false_challenge,
        expected_root_gc,
    };
    let prepared = prepare_dispute_packet(&config)?;

    let selected_is_mismatch = prepared
        .mismatch_indices
        .contains(&prepared.gate_index);
    println!("status=prepared");
    println!("bit_width={}", bit_width);
    println!("circuit_id={}", hex32(circuit_id));
    println!("instance_id={}", instance_id);
    println!("selected_gate_index={}", prepared.gate_index);
    println!("selected_gate_mismatch={selected_is_mismatch}");
    println!("mismatch_count={}", prepared.mismatch_indices.len());
    println!("mismatch_indices={:?}", prepared.mismatch_indices);
    println!("root_gc={}", hex32(prepared.root_gc));
    println!("layout_root={}", hex32(prepared.layout_root));
    println!("seed={}", hex32(seed));
    println!("gate_type={}", prepared.gate.gate_type as u8);
    println!("wire_a={}", prepared.gate.wire_a);
    println!("wire_b={}", prepared.gate.wire_b);
    println!("wire_c={}", prepared.gate.wire_c);
    println!("claimed_leaf={}", hex_prefixed(&prepared.claimed_leaf));
    println!("expected_leaf={}", hex_prefixed(&prepared.expected_leaf));
    println!("ih_proof={}", bytes32_vec_literal(&prepared.ih_proof));
    println!("layout_proof={}", bytes32_vec_literal(&prepared.layout_proof));

    let contract_for_template =
        env::var("CONTRACT_ADDRESS").unwrap_or_else(|_| "<CONTRACT_ADDRESS>".to_string());
    let rpc_for_template = rpc_url();
    let gate_tuple = format!(
        "({},{},{},{})",
        prepared.gate.gate_type as u8,
        prepared.gate.wire_a,
        prepared.gate.wire_b,
        prepared.gate.wire_c
    );
    println!();
    println!("cast send template:");
    println!(
        "cast send {} \"disputeGarbledTable(uint256,bytes32,uint256,(uint8,uint16,uint16,uint16),bytes,bytes32[],bytes32[])\" {} {} {} \"{}\" {} \"{}\" \"{}\" --private-key <BOB_PRIVATE_KEY> --rpc-url {}",
        contract_for_template,
        instance_id,
        hex32(seed),
        prepared.gate_index,
        gate_tuple,
        hex_prefixed(&prepared.claimed_leaf),
        bytes32_vec_literal(&prepared.ih_proof),
        bytes32_vec_literal(&prepared.layout_proof),
        rpc_for_template
    );

    Ok(())
}

fn cmd_dispute(args: &[String]) -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let bob_private_key = required_env("BOB_PRIVATE_KEY")?;

    let instance_id = parse_u64(&required_flag_value(args, "--instance-id")?, "instance-id")?;
    let seed = parse_bytes32(&required_flag_value(args, "--seed")?)?;
    let gate_index = parse_u64(&required_flag_value(args, "--gate-index")?, "gate-index")?;
    let gate_type = parse_u8(&required_flag_value(args, "--gate-type")?, "gate-type")?;
    if gate_type > 2 {
        return Err(format!("gate-type must be 0, 1, or 2; got {gate_type}").into());
    }
    let wire_a = parse_u16(&required_flag_value(args, "--wire-a")?, "wire-a")?;
    let wire_b = parse_u16(&required_flag_value(args, "--wire-b")?, "wire-b")?;
    let wire_c = parse_u16(&required_flag_value(args, "--wire-c")?, "wire-c")?;
    let leaf_bytes = parse_leaf71(&required_flag_value(args, "--leaf-bytes")?)?;
    let ih_proof = parse_bytes32_list_csv(&required_flag_value(args, "--ih-proof")?)?;
    let layout_proof = parse_bytes32_list_csv(&required_flag_value(args, "--layout-proof")?)?;

    let gate_tuple = format!("({gate_type},{wire_a},{wire_b},{wire_c})");
    let ih_literal = bytes32_vec_literal(&ih_proof);
    let layout_literal = bytes32_vec_literal(&layout_proof);

    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address,
        "disputeGarbledTable(uint256,bytes32,uint256,(uint8,uint16,uint16,uint16),bytes,bytes32[],bytes32[])".to_string(),
        instance_id.to_string(),
        hex32(seed),
        gate_index.to_string(),
        gate_tuple,
        hex_prefixed(&leaf_bytes),
        ih_literal,
        layout_literal,
        "--private-key".to_string(),
        bob_private_key,
        "--rpc-url".to_string(),
        rpc_url,
    ])?;

    print_tx_summary("dispute", &tx_result);
    Ok(())
}

fn print_help() {
    println!("off-chain-bob commands:");
    println!("  deposit");
    println!("  choose --m <index>");
    println!("  prepare-dispute --instance-id <id> --seed <0x..32> --claimed-leaves-file <path> [--bit-width <bits>] [--gate-index <k>] [--circuit-id <0x..32>] [--expected-root-gc <0x..32>] [--allow-false-challenge]");
    println!("  dispute --instance-id <id> --seed <0x..32> --gate-index <k> --gate-type <0|1|2> --wire-a <u16> --wire-b <u16> --wire-c <u16> --leaf-bytes <0x..71> --ih-proof <0x..,0x..> --layout-proof <0x..,0x..>");
    println!();
    println!("Default command with no args: deposit");
}

fn main() -> AppResult<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("deposit");
    let tail = if args.is_empty() { &[][..] } else { &args[1..] };

    match command {
        "deposit" => cmd_deposit(),
        "choose" => cmd_choose(tail),
        "prepare-dispute" => cmd_prepare_dispute(tail),
        "dispute" => cmd_dispute(tail),
        "-h" | "--help" | "help" => {
            print_help();
            Ok(())
        }
        _ => Err(format!("Unknown command: {command}. Use --help.").into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn decode_hex_roundtrip_bytes32() {
        let raw = "0x1111111111111111111111111111111111111111111111111111111111111111";
        let parsed = parse_bytes32(raw).expect("bytes32 parse");
        assert_eq!(hex32(parsed), raw);
    }

    #[test]
    fn prepare_dispute_picks_first_mismatch() {
        let circuit_id = keccak256(&[b"millionaires-yao-v1"]);
        let seed = [0x22u8; 32];
        let bit_width = 4usize;
        let instance_id = 0u64;
        let layout = CircuitLayout {
            circuit_id,
            instance_id,
            gates: build_millionaires_layout(bit_width),
        };

        let mut claimed = garble_circuit(seed, &layout);
        claimed[0][0] ^= 1;
        let config = PrepareDisputeConfig {
            bit_width,
            circuit_id,
            instance_id,
            seed,
            claimed_leaves: claimed,
            gate_index: None,
            allow_false_challenge: false,
            expected_root_gc: None,
        };

        let prepared = prepare_dispute_packet(&config).expect("prepare dispute");
        assert_eq!(prepared.gate_index, 0);
        assert!(prepared.mismatch_indices.contains(&0));
        assert_ne!(prepared.claimed_leaf, prepared.expected_leaf);
    }

    #[test]
    fn prepare_dispute_rejects_false_challenge_by_default() {
        let circuit_id = keccak256(&[b"millionaires-yao-v1"]);
        let seed = [0x33u8; 32];
        let bit_width = 4usize;
        let instance_id = 0u64;
        let layout = CircuitLayout {
            circuit_id,
            instance_id,
            gates: build_millionaires_layout(bit_width),
        };

        let mut claimed = garble_circuit(seed, &layout);
        claimed[0][0] ^= 1;
        let config = PrepareDisputeConfig {
            bit_width,
            circuit_id,
            instance_id,
            seed,
            claimed_leaves: claimed,
            gate_index: Some(1),
            allow_false_challenge: false,
            expected_root_gc: None,
        };

        let err = prepare_dispute_packet(&config)
            .expect_err("false challenge should be rejected");
        assert!(err.to_string().contains("refusing false challenge"));
    }

    #[test]
    fn reads_claimed_leaves_file() {
        let leaf = [0xabu8; 71];
        let path = {
            let millis = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time")
                .as_millis();
            env::temp_dir().join(format!("claimed-leaves-{millis}.txt"))
        };

        fs::write(&path, format!("{}\n", hex_prefixed(&leaf))).expect("write temp file");
        let parsed = read_claimed_leaves_file(&path).expect("parse leaves");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0], leaf);
        let _ = fs::remove_file(path);
    }
}
