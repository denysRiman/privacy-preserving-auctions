use off_chain_common::cli::{
    bytes32_vec_literal, hex32, hex_prefixed, parse_bytes16, parse_bytes32, parse_bytes32_list_csv,
    parse_flag_value, parse_leaf71, parse_u16, parse_u64, parse_u8, print_tx_summary, required_env,
    required_flag_value, rpc_url, run_cast,
};
use off_chain_common::consensus::{keccak256, layout_leaf_hash};
use off_chain_common::evaluation::{evaluate_garbled_circuit, label16_to_bytes32, u64_to_bits_le, NotGateHint};
use off_chain_common::garble::garble_circuit;
use off_chain_common::ih::{gc_block_hash, ih_proof_from_hashes, incremental_root_from_hashes};
use off_chain_common::merkle::{merkle_proof_from_hashes, merkle_root_from_hashes};
use off_chain_common::scenario::build_millionaires_layout;
use off_chain_common::types::{CircuitLayout, GateDesc};
use std::env;
use std::error::Error;
use std::fs;
use std::path::Path;

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

#[derive(Debug, Clone)]
struct EvalMeta {
    bit_width: usize,
    circuit_id: [u8; 32],
    instance_id: u64,
    output_wire: u16,
    h0: [u8; 32],
    h1: [u8; 32],
    lout_true: [u8; 32],
    lout_false: [u8; 32],
}

fn parse_key_value_file(path: &Path) -> AppResult<Vec<(String, String)>> {
    let raw = fs::read_to_string(path)?;
    let mut out = Vec::new();
    for (line_idx, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((k, v)) = trimmed.split_once('=') else {
            return Err(format!("invalid key=value at {}:{}", path.display(), line_idx + 1).into());
        };
        out.push((k.trim().to_string(), v.trim().to_string()));
    }
    Ok(out)
}

fn key_value_get<'a>(entries: &'a [(String, String)], key: &str) -> AppResult<&'a str> {
    entries
        .iter()
        .find_map(|(k, v)| if k == key { Some(v.as_str()) } else { None })
        .ok_or_else(|| format!("missing key '{key}'").into())
}

fn read_eval_meta(path: &Path) -> AppResult<EvalMeta> {
    let entries = parse_key_value_file(path)?;

    let bit_width = parse_u64(key_value_get(&entries, "bit_width")?, "bit_width")? as usize;
    let circuit_id = parse_bytes32(key_value_get(&entries, "circuit_id")?)?;
    let instance_id = parse_u64(key_value_get(&entries, "instance_id")?, "instance_id")?;
    let output_wire = parse_u16(key_value_get(&entries, "output_wire")?, "output_wire")?;
    let h0 = parse_bytes32(key_value_get(&entries, "h0")?)?;
    let h1 = parse_bytes32(key_value_get(&entries, "h1")?)?;
    let lout_true = parse_bytes32(key_value_get(&entries, "lout_true")?)?;
    let lout_false = parse_bytes32(key_value_get(&entries, "lout_false")?)?;

    Ok(EvalMeta {
        bit_width,
        circuit_id,
        instance_id,
        output_wire,
        h0,
        h1,
        lout_true,
        lout_false,
    })
}

fn read_label16_lines(path: &Path) -> AppResult<Vec<[u8; 16]>> {
    let raw = fs::read_to_string(path)?;
    let mut out = Vec::new();
    for (line_idx, line) in raw.lines().enumerate() {
        let value = line
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
        let parsed = parse_bytes16(value).map_err(|e| {
            format!(
                "invalid 16-byte label at {}:{}: {}",
                path.display(),
                line_idx + 1,
                e
            )
        })?;
        out.push(parsed);
    }
    if out.is_empty() {
        return Err(format!("No 16-byte labels found in {}", path.display()).into());
    }
    Ok(out)
}

fn read_leaf71_lines(path: &Path) -> AppResult<Vec<[u8; 71]>> {
    read_claimed_leaves_file(path)
}

fn read_y_offers(path: &Path, bit_width: usize) -> AppResult<Vec<([u8; 16], [u8; 16])>> {
    let raw = fs::read_to_string(path)?;
    let mut out = vec![None::<([u8; 16], [u8; 16])>; bit_width];

    for (line_idx, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let parts = trimmed.split(',').map(|s| s.trim()).collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err(format!(
                "invalid offer row at {}:{} (expected wire,label0,label1)",
                path.display(),
                line_idx + 1
            )
            .into());
        }
        let wire_id = parse_u64(parts[0], "wire_id")? as usize;
        if wire_id < bit_width || wire_id >= 2 * bit_width {
            return Err(format!(
                "offer wire_id {} out of expected y range [{}, {})",
                wire_id,
                bit_width,
                2 * bit_width
            )
            .into());
        }
        let idx = wire_id - bit_width;
        out[idx] = Some((parse_bytes16(parts[1])?, parse_bytes16(parts[2])?));
    }

    out.into_iter()
        .enumerate()
        .map(|(idx, maybe)| maybe.ok_or_else(|| format!("missing offer for y-bit {idx}").into()))
        .collect()
}

fn read_not_hints(path: &Path) -> AppResult<Vec<NotGateHint>> {
    let raw = fs::read_to_string(path)?;
    let mut out = Vec::new();

    for (line_idx, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let parts = trimmed.split(',').map(|s| s.trim()).collect::<Vec<_>>();
        if parts.len() != 5 {
            return Err(format!(
                "invalid NOT hint at {}:{} (expected gate,in0,out0,in1,out1)",
                path.display(),
                line_idx + 1
            )
            .into());
        }

        out.push(NotGateHint {
            gate_index: parse_u64(parts[0], "gate_index")? as usize,
            in_label0: parse_bytes16(parts[1])?,
            out_if_in0: parse_bytes16(parts[2])?,
            in_label1: parse_bytes16(parts[3])?,
            out_if_in1: parse_bytes16(parts[4])?,
        });
    }

    Ok(out)
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

fn cmd_evaluate_m(args: &[String]) -> AppResult<()> {
    let eval_dir = Path::new(&required_flag_value(args, "--eval-dir")?).to_path_buf();
    let y_value = parse_u64(&required_flag_value(args, "--y")?, "y")?;

    let meta = read_eval_meta(&eval_dir.join("eval-meta.txt"))?;
    if meta.bit_width < 64 && y_value >= (1u64 << meta.bit_width) {
        return Err(format!(
            "y={} does not fit bit-width {} (max={})",
            y_value,
            meta.bit_width,
            (1u64 << meta.bit_width) - 1
        )
        .into());
    }

    let leaves = read_leaf71_lines(&eval_dir.join("gc-m-leaves.txt"))?;
    let alice_labels = read_label16_lines(&eval_dir.join("alice-x-labels16.txt"))?;
    let y_offers = read_y_offers(&eval_dir.join("bob-y-offers.txt"), meta.bit_width)?;
    let not_hints = read_not_hints(&eval_dir.join("not-hints.txt"))?;

    if alice_labels.len() != meta.bit_width {
        return Err(format!(
            "alice label count {} does not match bit-width {}",
            alice_labels.len(),
            meta.bit_width
        )
        .into());
    }

    let y_bits = u64_to_bits_le(y_value, meta.bit_width);
    let bob_labels = y_bits
        .iter()
        .enumerate()
        .map(|(idx, bit)| if *bit == 0 { y_offers[idx].0 } else { y_offers[idx].1 })
        .collect::<Vec<_>>();

    let gates = build_millionaires_layout(meta.bit_width);
    let layout = CircuitLayout {
        circuit_id: meta.circuit_id,
        instance_id: meta.instance_id,
        gates,
    };

    let evaluated_label16 = evaluate_garbled_circuit(
        &layout,
        &leaves,
        &alice_labels,
        &bob_labels,
        &not_hints,
        meta.output_wire,
    )
    .map_err(|e| format!("evaluate-m failed: {e}"))?;
    let evaluated_label32 = label16_to_bytes32(evaluated_label16);

    let decoded_bit = if evaluated_label32 == meta.lout_true {
        Some(1u8)
    } else if evaluated_label32 == meta.lout_false {
        Some(0u8)
    } else {
        None
    };

    println!("status=evaluated");
    println!("instance_id={}", meta.instance_id);
    println!("bit_width={}", meta.bit_width);
    println!("y_value={y_value}");
    println!("selected_y_labels={}", bob_labels.len());
    println!("not_hint_count={}", not_hints.len());
    println!("output_wire={}", meta.output_wire);
    println!("output_label={}", hex32(evaluated_label32));
    println!("h0={}", hex32(meta.h0));
    println!("h1={}", hex32(meta.h1));
    println!("matches_h0={}", keccak256(&[&evaluated_label32]) == meta.h0);
    println!("matches_h1={}", keccak256(&[&evaluated_label32]) == meta.h1);
    if let Some(bit) = decoded_bit {
        println!("decoded_bit={bit}");
    } else {
        println!("decoded_bit=unknown");
    }

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
    println!("  evaluate-m --eval-dir <path> --y <u64>");
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
        "evaluate-m" => cmd_evaluate_m(tail),
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
