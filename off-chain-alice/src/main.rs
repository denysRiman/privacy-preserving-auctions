use off_chain_common::cli::{
    hex16, hex32, hex_prefixed, parse_bytes32, parse_bytes32_list_csv, parse_flag_value, parse_u64,
    print_tx_summary, required_env, required_env_any, required_flag_value, rpc_url, run_cast,
};
use off_chain_common::consensus::{derive_wire_label, keccak256};
use off_chain_common::evaluation::{
    derive_alice_input_labels, derive_bob_label_offers, derive_not_gate_hints, derive_output_labels,
    label16_to_bytes32, millionaires_gt_output_wire,
};
use off_chain_common::garble::garble_circuit;
use off_chain_common::ih::{gc_block_hash, incremental_root_from_hashes};
use off_chain_common::scenario::{CUT_AND_CHOOSE_N, build_millionaires_layout, com_seed, derive_instance_seed};
use off_chain_common::types::CircuitLayout;
use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};

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

fn ensure_value_fits_bits(value: u64, bit_width: usize, name: &str) -> AppResult<()> {
    if bit_width >= 64 {
        return Ok(());
    }
    if value >= (1u64 << bit_width) {
        return Err(format!(
            "{name}={} does not fit bit-width {} (max={})",
            value,
            bit_width,
            (1u64 << bit_width) - 1
        )
        .into());
    }
    Ok(())
}

fn hash_output_label(label16: [u8; 16]) -> [u8; 32] {
    let as_bytes32 = label16_to_bytes32(label16);
    keccak256(&[&as_bytes32])
}

fn derive_anchor_lists(config: &SessionConfig) -> AppResult<(Vec<[u8; 32]>, Vec<[u8; 32]>)> {
    let gates = build_millionaires_layout(config.bit_width);
    let out_wire = millionaires_gt_output_wire(&gates, config.bit_width)
        .map_err(|e| format!("failed to resolve millionaire output wire: {e}"))?;

    let mut h0 = Vec::with_capacity(CUT_AND_CHOOSE_N);
    let mut h1 = Vec::with_capacity(CUT_AND_CHOOSE_N);
    for instance_id in 0..CUT_AND_CHOOSE_N {
        let seed = derive_instance_seed(config.master_seed, config.circuit_id, instance_id as u64);
        // Contract `result=true` on h0 match. Map h0 to semantic true (x > y = 1) for readability.
        let l_true = derive_wire_label(config.circuit_id, instance_id as u64, out_wire, 1, seed);
        let l_false = derive_wire_label(config.circuit_id, instance_id as u64, out_wire, 0, seed);
        h0.push(hash_output_label(l_true));
        h1.push(hash_output_label(l_false));
    }
    Ok((h0, h1))
}

fn cmd_derive_anchors(args: &[String]) -> AppResult<()> {
    let config = parse_session_config(args)?;
    let (h0, h1) = derive_anchor_lists(&config)?;

    println!("bit_width={}", config.bit_width);
    println!("circuit_id={}", hex32(config.circuit_id));
    println!("h0_list={}", bytes32_vec_literal(&h0));
    println!("h1_list={}", bytes32_vec_literal(&h1));
    Ok(())
}

fn cmd_prepare_eval(args: &[String]) -> AppResult<()> {
    let config = parse_session_config(args)?;
    let m = parse_u64(&required_flag_value(args, "--m")?, "m")? as usize;
    let x_value = parse_u64(&required_flag_value(args, "--x")?, "x")?;
    let out_dir = PathBuf::from(required_flag_value(args, "--out-dir")?);

    ensure_value_fits_bits(x_value, config.bit_width, "x")?;
    if m >= CUT_AND_CHOOSE_N {
        return Err(format!("m={} out of range [0, {})", m, CUT_AND_CHOOSE_N).into());
    }

    let instances = build_instances(&config);
    let inst = &instances[m];
    let gates = build_millionaires_layout(config.bit_width);
    let layout = CircuitLayout {
        circuit_id: config.circuit_id,
        instance_id: m as u64,
        gates: gates.clone(),
    };

    let out_wire = millionaires_gt_output_wire(&gates, config.bit_width)
        .map_err(|e| format!("failed to resolve millionaire output wire: {e}"))?;
    let (l0, l1) = derive_output_labels(inst.seed, &layout, out_wire)
        .map_err(|e| format!("failed to derive output labels: {e}"))?;
    let l_true_32 = label16_to_bytes32(l1);
    let l_false_32 = label16_to_bytes32(l0);
    let h0 = keccak256(&[&l_true_32]);
    let h1 = keccak256(&[&l_false_32]);

    let alice_labels16 = derive_alice_input_labels(
        inst.seed,
        config.circuit_id,
        m as u64,
        config.bit_width,
        x_value,
    );
    let alice_labels32 = alice_labels16
        .iter()
        .map(|label| label16_to_bytes32(*label))
        .collect::<Vec<_>>();

    let y_offers = derive_bob_label_offers(inst.seed, config.circuit_id, m as u64, config.bit_width);
    let not_hints = derive_not_gate_hints(inst.seed, &layout);

    fs::create_dir_all(&out_dir)?;

    let leaves_file = out_dir.join("gc-m-leaves.txt");
    let mut leaves_raw = String::new();
    for leaf in &inst.leaves {
        leaves_raw.push_str(&hex_prefixed(leaf));
        leaves_raw.push('\n');
    }
    fs::write(&leaves_file, leaves_raw)?;

    let x16_file = out_dir.join("alice-x-labels16.txt");
    let mut x16_raw = String::new();
    for label in &alice_labels16 {
        x16_raw.push_str(&hex16(*label));
        x16_raw.push('\n');
    }
    fs::write(&x16_file, x16_raw)?;

    let x32_file = out_dir.join("alice-x-labels32.txt");
    let mut x32_raw = String::new();
    for label in &alice_labels32 {
        x32_raw.push_str(&hex32(*label));
        x32_raw.push('\n');
    }
    fs::write(&x32_file, x32_raw)?;

    let offers_file = out_dir.join("bob-y-offers.txt");
    let mut offers_raw = String::new();
    for (idx, (l0, l1)) in y_offers.iter().enumerate() {
        let wire_id = config.bit_width + idx;
        offers_raw.push_str(&format!("{wire_id},{},{}\n", hex16(*l0), hex16(*l1)));
    }
    fs::write(&offers_file, offers_raw)?;

    let hints_file = out_dir.join("not-hints.txt");
    let mut hints_raw = String::new();
    for hint in &not_hints {
        hints_raw.push_str(&format!(
            "{},{},{},{},{}\n",
            hint.gate_index,
            hex16(hint.in_label0),
            hex16(hint.out_if_in0),
            hex16(hint.in_label1),
            hex16(hint.out_if_in1)
        ));
    }
    fs::write(&hints_file, hints_raw)?;

    let meta_file = out_dir.join("eval-meta.txt");
    let meta = format!(
        "bit_width={}\ncircuit_id={}\ninstance_id={}\noutput_wire={}\nh0={}\nh1={}\nlout_true={}\nlout_false={}\n",
        config.bit_width,
        hex32(config.circuit_id),
        m,
        out_wire,
        hex32(h0),
        hex32(h1),
        hex32(l_true_32),
        hex32(l_false_32)
    );
    fs::write(&meta_file, meta)?;

    println!("status=prepared_eval");
    println!("eval_dir={}", out_dir.display());
    println!("instance_id={m}");
    println!("x_value={x_value}");
    println!("output_wire={out_wire}");
    println!("h0={}", hex32(h0));
    println!("h1={}", hex32(h1));
    println!("lout_true={}", hex32(l_true_32));
    println!("lout_false={}", hex32(l_false_32));
    println!("x_labels_count={}", alice_labels32.len());
    println!("y_offer_count={}", y_offers.len());
    println!("not_hint_count={}", not_hints.len());
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
    println!("  derive-anchors [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>]");
    println!("  submit-commitments [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>] [--root-gcs <0x..,0x.. x10>] [--blob-hashes <0x..,0x.. x10>] [--h0 <0x..,0x.. x10>] [--h1 <0x..,0x.. x10>] [--export-dir <path>]");
    println!("  export-artifacts --out-dir <path> [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>]");
    println!("  prepare-eval --m <index> --x <u64> --out-dir <path> [--bit-width <bits>] [--circuit-id <0x..32>] [--master-seed <0x..32>]");
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
        "derive-anchors" => cmd_derive_anchors(tail),
        "submit-commitments" => cmd_submit_commitments(tail),
        "export-artifacts" => cmd_export_artifacts(tail),
        "prepare-eval" => cmd_prepare_eval(tail),
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
