use std::env;
use std::error::Error;
use std::process::Command;

type AppResult<T> = Result<T, Box<dyn Error>>;

fn required_env(name: &str) -> AppResult<String> {
    env::var(name).map_err(|_| format!("Missing required env var: {name}").into())
}

fn run_cast(args: &[&str]) -> AppResult<String> {
    let output = Command::new("cast").args(args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("cast {} failed: {}", args.join(" "), stderr.trim()).into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn main() -> AppResult<()> {
    // Minimal env-driven config for local Anvil/Foundry workflow.
    let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string());
    let contract_address = required_env("CONTRACT_ADDRESS")?;
    let bob_private_key = required_env("BOB_PRIVATE_KEY")?;
    let deposit_wei = env::var("DEPOSIT_WEI").unwrap_or_else(|_| "1000000000000000000".to_string()); // 1 ETH

    // Preflight check: confirm cast exists.
    let cast_version = run_cast(&["--version"])?;
    println!("using {cast_version}");

    // Helpful visibility before sending transaction.
    let stage_before = run_cast(&[
        "call",
        contract_address.as_str(),
        "currentStage()(uint8)",
        "--rpc-url",
        rpc_url.as_str(),
    ])?;
    println!("stage_before={stage_before}");

    let configured_bob = run_cast(&[
        "call",
        contract_address.as_str(),
        "bob()(address)",
        "--rpc-url",
        rpc_url.as_str(),
    ])?;
    let signer_bob = run_cast(&[
        "wallet",
        "address",
        "--private-key",
        bob_private_key.as_str(),
    ])?;
    println!("configured_bob={configured_bob}");
    println!("signer_bob={signer_bob}");

    println!(
        "sending deposit() to {} with value={} wei",
        contract_address, deposit_wei
    );
    let tx_result = run_cast(&[
        "send",
        contract_address.as_str(),
        "deposit()",
        "--value",
        deposit_wei.as_str(),
        "--private-key",
        bob_private_key.as_str(),
        "--rpc-url",
        rpc_url.as_str(),
    ])?;
    println!("deposit_tx:\n{tx_result}");

    let bob_vault = run_cast(&[
        "call",
        contract_address.as_str(),
        "vault(address)(uint256)",
        signer_bob.as_str(),
        "--rpc-url",
        rpc_url.as_str(),
    ])?;
    let stage_after = run_cast(&[
        "call",
        contract_address.as_str(),
        "currentStage()(uint8)",
        "--rpc-url",
        rpc_url.as_str(),
    ])?;
    println!("bob_vault={bob_vault}");
    println!("stage_after={stage_after}");

    Ok(())
}
