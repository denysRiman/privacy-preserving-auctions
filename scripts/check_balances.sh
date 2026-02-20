#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ALICE_PK="${ALICE_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
BOB_PK="${BOB_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
EXPECTED_CONTRACT_WEI="${EXPECTED_CONTRACT_WEI:-1000000000000000000}" # 1 ETH by default

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd cast
require_cmd curl

if ! curl -sS -X POST "${RPC_URL}" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null; then
  echo "Cannot reach RPC at ${RPC_URL}" >&2
  exit 1
fi

# Priority:
# 1) CONTRACT_ADDRESS env
# 2) first arg
# 3) parse /tmp/local_bob_deploy.log
CONTRACT_ADDRESS="${CONTRACT_ADDRESS:-${1:-}}"
if [[ -z "${CONTRACT_ADDRESS}" && -f /tmp/local_bob_deploy.log ]]; then
  CONTRACT_ADDRESS="$(
    sed -nE 's/.*"deployedTo"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p' /tmp/local_bob_deploy.log | tail -n1
  )"
fi

if [[ -z "${CONTRACT_ADDRESS}" ]]; then
  cat >&2 <<EOF
Missing CONTRACT_ADDRESS.
Usage:
  CONTRACT_ADDRESS=0x... ./scripts/check_balances.sh
or:
  ./scripts/check_balances.sh 0x...
EOF
  exit 1
fi

ALICE_ADDR="$(cast wallet address --private-key "${ALICE_PK}")"
BOB_ADDR="$(cast wallet address --private-key "${BOB_PK}")"

ALICE_BAL_WEI="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
BOB_BAL_WEI="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"
CONTRACT_BAL_WEI="$(cast balance "${CONTRACT_ADDRESS}" --rpc-url "${RPC_URL}")"

ALICE_BAL_ETH="$(cast from-wei "${ALICE_BAL_WEI}")"
BOB_BAL_ETH="$(cast from-wei "${BOB_BAL_WEI}")"
CONTRACT_BAL_ETH="$(cast from-wei "${CONTRACT_BAL_WEI}")"
echo "bob_eth=${BOB_BAL_ETH}"
echo "alice_eth=${ALICE_BAL_ETH}"
echo "contract_eth=${CONTRACT_BAL_ETH}"
