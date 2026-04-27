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

    let has_blob_tx = out.iter().any(|arg| arg == "--blob");

    if env_truthy("TX_LEGACY") && !has_blob_tx && !out.iter().any(|arg| arg == "--legacy") {
        out.push("--legacy".to_string());
    }

    if !has_blob_tx && !out.iter().any(|arg| arg == "--gas-price") {
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

pub fn tx_summary_lines(label: &str, output: &str) -> Vec<String> {
    let mut emitted = false;
    let mut lines = Vec::new();
    if let Some(tx_hash) = cast_output_field(output, "transactionHash") {
        lines.push(format!("{label}_tx_hash={tx_hash}"));
        emitted = true;
    }
    if let Some(status) = cast_output_field(output, "status") {
        lines.push(format!("{label}_status={status}"));
        emitted = true;
    }
    if let Some(gas_used) = cast_output_field(output, "gasUsed") {
        lines.push(format!("{label}_gas_used={gas_used}"));
        emitted = true;
    }
    if let Some(cumulative_gas_used) = cast_output_field(output, "cumulativeGasUsed") {
        lines.push(format!("{label}_cumulative_gas_used={cumulative_gas_used}"));
        emitted = true;
    }
    if let Some(effective_gas_price) = cast_output_field(output, "effectiveGasPrice") {
        lines.push(format!("{label}_effective_gas_price={effective_gas_price}"));
        emitted = true;
    }
    if emitted {
        return lines;
    }

    if let Some(first_line) = output.lines().next() {
        lines.push(format!("{label}_tx={first_line}"));
    } else {
        lines.push(format!("{label}_tx=submitted"));
    }
    lines
}

pub fn print_tx_summary(label: &str, output: &str) {
    for line in tx_summary_lines(label, output) {
        println!("{line}");
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

    let normalized = trimmed.trim_start_matches('[').trim_end_matches(']').trim();
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
    parse_flag_value(args, flag).ok_or_else(|| format!("Missing required argument: {flag}").into())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tx_summary_lines_emit_all_receipt_fields_in_stable_order() {
        let receipt = concat!(
            "transactionHash 0xabc123\n",
            "status 1\n",
            "gasUsed 21000\n",
            "cumulativeGasUsed 42000\n",
            "effectiveGasPrice 1000000000\n",
        );

        assert_eq!(
            tx_summary_lines("settle_auction", receipt),
            vec![
                "settle_auction_tx_hash=0xabc123",
                "settle_auction_status=1",
                "settle_auction_gas_used=21000",
                "settle_auction_cumulative_gas_used=42000",
                "settle_auction_effective_gas_price=1000000000",
            ]
        );
    }

    #[test]
    fn tx_summary_lines_preserve_legacy_fallbacks() {
        assert_eq!(
            tx_summary_lines("commit", "0xdeadbeef\nignored"),
            vec!["commit_tx=0xdeadbeef"]
        );
        assert_eq!(tx_summary_lines("commit", ""), vec!["commit_tx=submitted"]);
    }
}
