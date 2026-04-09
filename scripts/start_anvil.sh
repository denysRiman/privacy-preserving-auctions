#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8545}"
BASE_FEE_WEI="${BASE_FEE_WEI:-0}"
GAS_PRICE_WEI="${GAS_PRICE_WEI:-0}"
CODE_SIZE_LIMIT="${CODE_SIZE_LIMIT:-50000}"

echo "Starting Anvil on ${HOST}:${PORT} (base_fee=${BASE_FEE_WEI}, gas_price=${GAS_PRICE_WEI}, code_size_limit=${CODE_SIZE_LIMIT})"
anvil --host "${HOST}" --port "${PORT}" --base-fee "${BASE_FEE_WEI}" --gas-price "${GAS_PRICE_WEI}" --code-size-limit "${CODE_SIZE_LIMIT}"
