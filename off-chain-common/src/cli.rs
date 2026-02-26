use std::env;
use std::error::Error;
use std::process::Command;

pub type CliResult<T> = Result<T, Box<dyn Error>>;

pub fn required_env(name: &str) -> CliResult<String> {
    env::var(name).map_err(|_| format!("Missing required env var: {name}").into())
}

pub fn required_env_any(names: &[&str]) -> CliResult<String> {
    for name in names {
        if let Ok(value) = env::var(name) {
            if !value.trim().is_empty() {
                return Ok(value);
            }
        }
    }
    Err(format!("Missing required env vars: {}", names.join(" or ")).into())
}

pub fn rpc_url() -> String {
    env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string())
}

pub fn env_truthy(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => {
            let normalized = value.trim().to_ascii_lowercase();
            matches!(normalized.as_str(), "1" | "true" | "yes" | "on")
        }
        Err(_) => false,
    }
}

pub fn cast_args_with_tx_overrides(args: &[String]) -> Vec<String> {
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

pub fn run_cast(args: &[String]) -> CliResult<String> {
    let final_args = cast_args_with_tx_overrides(args);
    let output = Command::new("cast").args(&final_args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("cast {} failed: {}", final_args.join(" "), stderr.trim()).into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn cast_output_field(output: &str, key: &str) -> Option<String> {
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

pub fn print_tx_summary(label: &str, output: &str) {
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

fn hex_nibble(value: u8) -> CliResult<u8> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(10 + value - b'a'),
        b'A'..=b'F' => Ok(10 + value - b'A'),
        _ => Err(format!("invalid hex character: {}", value as char).into()),
    }
}

pub fn strip_0x(value: &str) -> &str {
    value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value)
}

pub fn decode_hex(value: &str) -> CliResult<Vec<u8>> {
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

pub fn parse_fixed_bytes<const N: usize>(value: &str) -> CliResult<[u8; N]> {
    let decoded = decode_hex(value)?;
    if decoded.len() != N {
        return Err(format!("expected {N} bytes, got {}", decoded.len()).into());
    }
    let mut out = [0u8; N];
    out.copy_from_slice(&decoded);
    Ok(out)
}

pub fn parse_bytes32(value: &str) -> CliResult<[u8; 32]> {
    parse_fixed_bytes::<32>(value)
}

pub fn parse_bytes16(value: &str) -> CliResult<[u8; 16]> {
    parse_fixed_bytes::<16>(value)
}

pub fn parse_leaf71(value: &str) -> CliResult<[u8; 71]> {
    parse_fixed_bytes::<71>(value)
}

pub fn parse_bytes32_list_csv(value: &str) -> CliResult<Vec<[u8; 32]>> {
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

pub fn parse_flag_value(args: &[String], flag: &str) -> Option<String> {
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

pub fn required_flag_value(args: &[String], flag: &str) -> CliResult<String> {
    parse_flag_value(args, flag)
        .ok_or_else(|| format!("Missing required argument: {flag}").into())
}

pub fn parse_u64(value: &str, name: &str) -> CliResult<u64> {
    value
        .parse::<u64>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

pub fn parse_u16(value: &str, name: &str) -> CliResult<u16> {
    value
        .parse::<u16>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

pub fn parse_u8(value: &str, name: &str) -> CliResult<u8> {
    value
        .parse::<u8>()
        .map_err(|_| format!("Invalid {name}: {value}").into())
}

pub fn hex_prefixed(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

pub fn hex32(value: [u8; 32]) -> String {
    hex_prefixed(&value)
}

pub fn hex16(value: [u8; 16]) -> String {
    hex_prefixed(&value)
}

pub fn bytes32_vec_literal(values: &[[u8; 32]]) -> String {
    if values.is_empty() {
        return "[]".to_string();
    }
    let parts = values.iter().map(|v| hex32(*v)).collect::<Vec<_>>();
    format!("[{}]", parts.join(","))
}
