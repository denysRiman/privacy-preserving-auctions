#!/usr/bin/env bash
set -euo pipefail

# End-to-end local flow:
# 1) Deploy MillionairesProblem from Alice account
# 2) Call deposit() from Bob backend (off-chain-bob)
# 3) Print Bob vault and stage after deposit

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${ROOT_DIR}/contract"
BOB_APP_DIR="${ROOT_DIR}/off-chain-bob"

# Defaults are Anvil standard first two accounts.
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ALICE_PK="${ALICE_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
BOB_PK="${BOB_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
DEPOSIT_WEI="${DEPOSIT_WEI:-1000000000000000000}"

# Placeholder deterministic constants for constructor args.
CIRCUIT_ID="${CIRCUIT_ID:-0x1111111111111111111111111111111111111111111111111111111111111111}"
LAYOUT_ROOT="${LAYOUT_ROOT:-0x2222222222222222222222222222222222222222222222222222222222222222}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

echo "== Preflight =="
require_cmd cast
require_cmd forge
require_cmd cargo
require_cmd curl

if ! curl -sS -X POST "${RPC_URL}" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null; then
  cat >&2 <<EOF
Cannot reach RPC at ${RPC_URL}.
Start local chain first:
  ./scripts/start_anvil.sh
EOF
  exit 1
fi

BOB_ADDR="$(cast wallet address --private-key "${BOB_PK}")"
echo "bob_address=${BOB_ADDR}"

echo "== Deploy MillionairesProblem =="
DEPLOY_OUT="$(
  cd "${CONTRACT_DIR}" && forge create src/MillionairesProblem.sol:MillionairesProblem \
    --rpc-url "${RPC_URL}" \
    --private-key "${ALICE_PK}" \
    --broadcast \
    --json \
    --constructor-args "${BOB_ADDR}" "${CIRCUIT_ID}" "${LAYOUT_ROOT}" 2>&1
)"
echo "${DEPLOY_OUT}"

if echo "${DEPLOY_OUT}" | grep -q "Dry run enabled, not broadcasting transaction"; then
  cat >&2 <<EOF
Deployment ran as dry-run (not broadcast).
This usually means forge CLI flags were parsed unexpectedly.
Current command has been fixed to pass --broadcast before --constructor-args.
Please run again:
  ./scripts/local_bob_deposit.sh
EOF
  exit 1
fi

set +e
CONTRACT_ADDRESS="$(
  echo "${DEPLOY_OUT}" \
    | tr -d '\r' \
    | sed -nE 's/.*"deployedTo"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p' \
    | tail -n1
)"
set -e

if [[ -z "${CONTRACT_ADDRESS}" ]]; then
  # Fallback for non-JSON/legacy forge output.
  set +e
  CONTRACT_ADDRESS="$(
    echo "${DEPLOY_OUT}" \
      | tr -d '\r' \
      | grep -Eo 'Deployed to:[[:space:]]*0x[0-9a-fA-F]{40}' \
      | tail -n1 \
      | grep -Eo '0x[0-9a-fA-F]{40}'
  )"
  set -e
fi

if [[ -z "${CONTRACT_ADDRESS}" ]]; then
  echo "Failed to parse contract address from forge output." >&2
  echo "Last deploy output lines:" >&2
  echo "${DEPLOY_OUT}" | tail -n 40 >&2 || true
  echo "Tip: run this command manually to inspect output format:" >&2
  echo "  cd contract && forge create src/MillionairesProblem.sol:MillionairesProblem --rpc-url \"${RPC_URL}\" --private-key \"<ALICE_PK>\" --constructor-args \"${BOB_ADDR}\" \"${CIRCUIT_ID}\" \"${LAYOUT_ROOT}\" --json" >&2
  exit 1
fi
echo "contract_address=${CONTRACT_ADDRESS}"

echo "== Bob deposit() via off-chain-bob =="
(
  cd "${BOB_APP_DIR}"
  RPC_URL="${RPC_URL}" \
  CONTRACT_ADDRESS="${CONTRACT_ADDRESS}" \
  BOB_PRIVATE_KEY="${BOB_PK}" \
  DEPOSIT_WEI="${DEPOSIT_WEI}" \
  cargo run --offline
)

echo "== Final on-chain state =="
BOB_VAULT="$(
  cast call "${CONTRACT_ADDRESS}" "vault(address)(uint256)" "${BOB_ADDR}" --rpc-url "${RPC_URL}"
)"
STAGE="$(
  cast call "${CONTRACT_ADDRESS}" "currentStage()(uint8)" --rpc-url "${RPC_URL}"
)"
echo "bob_vault=${BOB_VAULT}"
echo "current_stage=${STAGE} (0 = Deposits)"
