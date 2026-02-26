use off_chain_test::consensus::keccak256;
use off_chain_test::garble::garble_circuit;
use off_chain_test::ih::{gc_block_hash, incremental_root_from_hashes};
use off_chain_test::scenario::{CUT_AND_CHOOSE_N, build_millionaires_layout, com_seed, derive_instance_seed};
use off_chain_test::types::CircuitLayout;
use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

type AppResult<T> = Result<T, Box<dyn Error>>;

#[derive(Debug, Clone)]
struct SessionConfig {
    bit_width: usize,
    circuit_id: [u8; 32],
    master_seed: [u8; 32],
}

#[derive(Debug, Clone)]
struct InstanceArtifacts {
    instance_id: usize,
    seed: [u8; 32],
    com_seed: [u8; 32],
    root_gc: [u8; 32],
    leaves: Vec<[u8; 71]>,
}

fn required_env(name: &str) -> AppResult<String> {
    env::var(name).map_err(|_| format!("Missing required env var: {name}").into())
}

fn required_env_any(names: &[&str]) -> AppResult<String> {
    for name in names {
        if let Ok(value) = env::var(name) {
            if !value.trim().is_empty() {
                return Ok(value);
            }
        }
    }
    Err(format!("Missing required env vars: {}", names.join(" or ")).into())
}

fn rpc_url() -> String {
    env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string())
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

fn parse_u64(value: &str, name: &str) -> AppResult<u64> {
    value
        .parse::<u64>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
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

fn uint_vec_literal(values: &[usize]) -> String {
    if values.is_empty() {
        return "[]".to_string();
    }
    let parts = values.iter().map(|v| v.to_string()).collect::<Vec<_>>();
    format!("[{}]", parts.join(","))
}

fn read_bytes32_lines_file(path: &Path) -> AppResult<Vec<[u8; 32]>> {
    let raw = fs::read_to_string(path)?;
    let mut out = Vec::new();

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

        value = value.trim_start_matches('[').trim_end_matches(']');
        if value.is_empty() {
            continue;
        }

        let parsed = parse_bytes32(value).map_err(|e| {
            format!(
                "invalid bytes32 line at {}:{}: {}",
                path.display(),
                line_idx + 1,
                e
            )
        })?;
        out.push(parsed);
    }

    if out.is_empty() {
        return Err(format!("No bytes32 values found in {}", path.display()).into());
    }
    Ok(out)
}

fn parse_session_config(args: &[String]) -> AppResult<SessionConfig> {
    let bit_width = parse_flag_value(args, "--bit-width")
        .as_deref()
        .map(|v| parse_u64(v, "bit-width"))
        .transpose()?
        .unwrap_or(8) as usize;
    let circuit_id = parse_flag_value(args, "--circuit-id")
        .as_deref()
        .map(parse_bytes32)
        .transpose()?
        .unwrap_or_else(|| keccak256(&[b"millionaires-yao-v1"]));
    let master_seed = parse_flag_value(args, "--master-seed")
        .as_deref()
        .map(parse_bytes32)
        .transpose()?
        .unwrap_or_else(|| keccak256(&[b"master-seed-v1"]));

    Ok(SessionConfig {
        bit_width,
        circuit_id,
        master_seed,
    })
}

fn build_instances(config: &SessionConfig) -> Vec<InstanceArtifacts> {
    let gates = build_millionaires_layout(config.bit_width);

    (0..CUT_AND_CHOOSE_N)
        .map(|instance_id| {
            let seed = derive_instance_seed(
                config.master_seed,
                config.circuit_id,
                instance_id as u64,
            );
            let layout = CircuitLayout {
                circuit_id: config.circuit_id,
                instance_id: instance_id as u64,
                gates: gates.clone(),
            };
            let leaves = garble_circuit(seed, &layout);
            let block_hashes = leaves
                .iter()
                .enumerate()
                .map(|(idx, leaf)| gc_block_hash(idx as u64, leaf))
                .collect::<Vec<_>>();
            let root_gc = incremental_root_from_hashes(&block_hashes);

            InstanceArtifacts {
                instance_id,
                seed,
                com_seed: com_seed(seed),
                root_gc,
                leaves,
            }
        })
        .collect()
}

fn opened_indices_and_seeds(
    instances: &[InstanceArtifacts],
    m: usize,
) -> AppResult<(Vec<usize>, Vec<[u8; 32]>)> {
    if instances.len() != CUT_AND_CHOOSE_N {
        return Err(format!(
            "expected {} instances, got {}",
            CUT_AND_CHOOSE_N,
            instances.len()
        )
        .into());
    }
    if m >= CUT_AND_CHOOSE_N {
        return Err(format!("m={} out of range [0, {})", m, CUT_AND_CHOOSE_N).into());
    }

    let mut indices = Vec::with_capacity(CUT_AND_CHOOSE_N - 1);
    let mut seeds = Vec::with_capacity(CUT_AND_CHOOSE_N - 1);
    for inst in instances {
        if inst.instance_id == m {
            continue;
        }
        indices.push(inst.instance_id);
        seeds.push(inst.seed);
    }
    Ok((indices, seeds))
}

fn write_instance_files(out_dir: &Path, instances: &[InstanceArtifacts]) -> AppResult<()> {
    fs::create_dir_all(out_dir)?;

    let mut manifest = String::new();
    manifest.push_str("# Alice artifacts\n");
    manifest.push_str("# file format: hex-encoded values\n\n");

    for inst in instances {
        let seed_file = out_dir.join(format!("instance-{}-seed.txt", inst.instance_id));
        let com_file = out_dir.join(format!("instance-{}-com-seed.txt", inst.instance_id));
        let root_file = out_dir.join(format!("instance-{}-root-gc.txt", inst.instance_id));
        let leaves_file = out_dir.join(format!("instance-{}-leaves.txt", inst.instance_id));

        fs::write(&seed_file, format!("{}\n", hex32(inst.seed)))?;
        fs::write(&com_file, format!("{}\n", hex32(inst.com_seed)))?;
        fs::write(&root_file, format!("{}\n", hex32(inst.root_gc)))?;

        let mut leaves_raw = String::new();
        for leaf in &inst.leaves {
            leaves_raw.push_str(&hex_prefixed(leaf));
            leaves_raw.push('\n');
        }
        fs::write(&leaves_file, leaves_raw)?;

        manifest.push_str(&format!(
            "instance {}:\n  seed={}\n  comSeed={}\n  rootGC={}\n  leaves={}\n\n",
            inst.instance_id,
            seed_file.display(),
            com_file.display(),
            root_file.display(),
            leaves_file.display()
        ));
    }

    fs::write(out_dir.join("manifest.txt"), manifest)?;
    Ok(())
}

fn cmd_deposit() -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let alice_private_key = required_env_any(&["ALICE_PRIVATE_KEY", "ALICE_PK"])?;
    let deposit_wei = env::var("DEPOSIT_WEI").unwrap_or_else(|_| "1000000000000000000".to_string());

    let stage_before = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "currentStage()(uint8)".to_string(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("stage_before={stage_before}");

    let configured_alice = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "alice()(address)".to_string(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    let signer_alice = run_cast(&[
        "wallet".to_string(),
        "address".to_string(),
        "--private-key".to_string(),
        alice_private_key.clone(),
    ])?;
    let wallet_before = run_cast(&[
        "balance".to_string(),
        signer_alice.clone(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("configured_alice={configured_alice}");
    println!("signer_alice={signer_alice}");
    println!("alice_wallet_before={wallet_before}");

    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address.clone(),
        "deposit()".to_string(),
        "--value".to_string(),
        deposit_wei,
        "--private-key".to_string(),
        alice_private_key,
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    print_tx_summary("deposit", &tx_result);
    let wallet_after = run_cast(&[
        "balance".to_string(),
        signer_alice.clone(),
        "--rpc-url".to_string(),
        rpc_url.clone(),
    ])?;
    println!("alice_wallet_after={wallet_after}");

    let vault = run_cast(&[
        "call".to_string(),
        contract_address.clone(),
        "vault(address)(uint256)".to_string(),
        signer_alice,
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
    println!("alice_vault={vault}");
    println!("stage_after={stage_after}");

    Ok(())
}

fn cmd_submit_commitments(args: &[String]) -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let alice_private_key = required_env_any(&["ALICE_PRIVATE_KEY", "ALICE_PK"])?;
    let config = parse_session_config(args)?;
    let instances = build_instances(&config);
    let zero = [0u8; 32];

    let root_gcs = if let Some(raw) = parse_flag_value(args, "--root-gcs") {
        let parsed = parse_bytes32_list_csv(&raw)?;
        if parsed.len() != CUT_AND_CHOOSE_N {
            return Err(format!(
                "--root-gcs must contain {} values, got {}",
                CUT_AND_CHOOSE_N,
                parsed.len()
            )
            .into());
        }
        parsed
    } else {
        instances.iter().map(|inst| inst.root_gc).collect::<Vec<_>>()
    };

    let blob_hashes = if let Some(raw) = parse_flag_value(args, "--blob-hashes") {
        let parsed = parse_bytes32_list_csv(&raw)?;
        if parsed.len() != CUT_AND_CHOOSE_N {
            return Err(format!(
                "--blob-hashes must contain {} values, got {}",
                CUT_AND_CHOOSE_N,
                parsed.len()
            )
            .into());
        }
        parsed
    } else {
        vec![zero; CUT_AND_CHOOSE_N]
    };

    let h0 = if let Some(raw) = parse_flag_value(args, "--h0") {
        let parsed = parse_bytes32_list_csv(&raw)?;
        if parsed.len() != CUT_AND_CHOOSE_N {
            return Err(format!(
                "--h0 must contain {} values, got {}",
                CUT_AND_CHOOSE_N,
                parsed.len()
            )
            .into());
        }
        parsed
    } else {
        vec![zero; CUT_AND_CHOOSE_N]
    };

    let h1 = if let Some(raw) = parse_flag_value(args, "--h1") {
        let parsed = parse_bytes32_list_csv(&raw)?;
        if parsed.len() != CUT_AND_CHOOSE_N {
            return Err(format!(
                "--h1 must contain {} values, got {}",
                CUT_AND_CHOOSE_N,
                parsed.len()
            )
            .into());
        }
        parsed
    } else {
        vec![zero; CUT_AND_CHOOSE_N]
    };

    if let Some(path) = parse_flag_value(args, "--export-dir") {
        write_instance_files(Path::new(&path), &instances)?;
        println!("artifacts_exported={path}");
    }

    let tuple_items = instances
        .iter()
        .map(|inst| {
            format!(
                "({},{},{},{},{},{},{})",
                hex32(inst.com_seed),
                hex32(root_gcs[inst.instance_id]),
                hex32(blob_hashes[inst.instance_id]),
                hex32(zero),
                hex32(zero),
                hex32(h0[inst.instance_id]),
                hex32(h1[inst.instance_id])
            )
        })
        .collect::<Vec<_>>();
    let commitments_arg = format!("[{}]", tuple_items.join(","));

    println!("circuit_id={}", hex32(config.circuit_id));
    println!("master_seed={}", hex32(config.master_seed));
    println!("bit_width={}", config.bit_width);
    for inst in &instances {
        println!(
            "instance={} comSeed={} rootGC={} blobHashGC={}",
            inst.instance_id,
            hex32(inst.com_seed),
            hex32(root_gcs[inst.instance_id]),
            hex32(blob_hashes[inst.instance_id])
        );
    }

    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address,
        "submitCommitments((bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)[10])"
            .to_string(),
        commitments_arg,
        "--private-key".to_string(),
        alice_private_key,
        "--rpc-url".to_string(),
        rpc_url,
    ])?;
    print_tx_summary("submit_commitments", &tx_result);
    Ok(())
}

fn cmd_export_artifacts(args: &[String]) -> AppResult<()> {
    let config = parse_session_config(args)?;
    let out_dir = required_flag_value(args, "--out-dir")?;
    let out_dir_path = PathBuf::from(out_dir);
    let instances = build_instances(&config);
    write_instance_files(&out_dir_path, &instances)?;

    println!("status=exported");
    println!("circuit_id={}", hex32(config.circuit_id));
    println!("master_seed={}", hex32(config.master_seed));
    println!("bit_width={}", config.bit_width);
    println!("out_dir={}", out_dir_path.display());
    Ok(())
}

fn cmd_reveal_openings(args: &[String]) -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let alice_private_key = required_env_any(&["ALICE_PRIVATE_KEY", "ALICE_PK"])?;

    let m = parse_u64(&required_flag_value(args, "--m")?, "m")? as usize;
    let config = parse_session_config(args)?;
    let instances = build_instances(&config);
    let (indices, seeds) = opened_indices_and_seeds(&instances, m)?;

    let indices_arg = uint_vec_literal(&indices);
    let seeds_arg = bytes32_vec_literal(&seeds);
    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address,
        "revealOpenings(uint256[],bytes32[])".to_string(),
        indices_arg,
        seeds_arg,
        "--private-key".to_string(),
        alice_private_key,
        "--rpc-url".to_string(),
        rpc_url,
    ])?;

    print_tx_summary("reveal_openings", &tx_result);
    println!("m={}", m);
    println!("open_indices={:?}", indices);
    Ok(())
}

fn cmd_reveal_labels(args: &[String]) -> AppResult<()> {
    let rpc_url = rpc_url();
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let alice_private_key = required_env_any(&["ALICE_PRIVATE_KEY", "ALICE_PK"])?;

    let labels = if let Some(raw) = parse_flag_value(args, "--labels") {
        parse_bytes32_list_csv(&raw)?
    } else if let Some(path) = parse_flag_value(args, "--labels-file") {
        read_bytes32_lines_file(Path::new(&path))?
    } else {
        return Err("Provide --labels or --labels-file".into());
    };

    let labels_arg = bytes32_vec_literal(&labels);
    let tx_result = run_cast(&[
        "send".to_string(),
        contract_address,
        "revealGarblerLabels(bytes32[])".to_string(),
        labels_arg,
        "--private-key".to_string(),
        alice_private_key,
        "--rpc-url".to_string(),
        rpc_url,
    ])?;

    print_tx_summary("reveal_labels", &tx_result);
    println!("labels_count={}", labels.len());
    Ok(())
}

fn print_help() {
    println!("off-chain-alice commands:");
    println!("  deposit");
    println!("  submit-commitments [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>] [--root-gcs <0x..,0x.. x10>] [--blob-hashes <0x..,0x.. x10>] [--h0 <0x..,0x.. x10>] [--h1 <0x..,0x.. x10>] [--export-dir <path>]");
    println!("  export-artifacts --out-dir <path> [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>]");
    println!("  reveal-openings --m <index> [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>]");
    println!("  reveal-labels (--labels <0x..,0x..> | --labels-file <path>)");
    println!();
    println!("Default command with no args: deposit");
}

fn main() -> AppResult<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("deposit");
    let tail = if args.is_empty() { &[][..] } else { &args[1..] };

    match command {
        "deposit" => cmd_deposit(),
        "submit-commitments" => cmd_submit_commitments(tail),
        "export-artifacts" => cmd_export_artifacts(tail),
        "reveal-openings" => cmd_reveal_openings(tail),
        "reveal-labels" => cmd_reveal_labels(tail),
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

    fn test_config() -> SessionConfig {
        SessionConfig {
            bit_width: 4,
            circuit_id: keccak256(&[b"millionaires-yao-v1"]),
            master_seed: keccak256(&[b"master-seed-v1"]),
        }
    }

    #[test]
    fn builds_all_instances() {
        let instances = build_instances(&test_config());
        assert_eq!(instances.len(), CUT_AND_CHOOSE_N);
        assert!(instances.iter().all(|i| i.root_gc != [0u8; 32]));
        assert!(instances.iter().all(|i| i.com_seed != [0u8; 32]));
    }

    #[test]
    fn openings_exclude_m() {
        let instances = build_instances(&test_config());
        let (indices, seeds) = opened_indices_and_seeds(&instances, 7).expect("openings");
        assert_eq!(indices.len(), CUT_AND_CHOOSE_N - 1);
        assert_eq!(seeds.len(), CUT_AND_CHOOSE_N - 1);
        assert!(!indices.contains(&7));
    }

    #[test]
    fn parses_bytes32_list() {
        let raw = "[0x1111111111111111111111111111111111111111111111111111111111111111,0x2222222222222222222222222222222222222222222222222222222222222222]";
        let parsed = parse_bytes32_list_csv(raw).expect("parse csv");
        assert_eq!(parsed.len(), 2);
        assert_eq!(
            hex32(parsed[0]),
            "0x1111111111111111111111111111111111111111111111111111111111111111"
        );
    }

    #[test]
    fn reads_labels_file() {
        let path = {
            let millis = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time")
                .as_millis();
            env::temp_dir().join(format!("alice-labels-{millis}.txt"))
        };
        fs::write(
            &path,
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        )
        .expect("write temp labels");

        let labels = read_bytes32_lines_file(&path).expect("read labels");
        assert_eq!(labels.len(), 1);
        assert_eq!(
            hex32(labels[0]),
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        let _ = fs::remove_file(path);
    }
}
