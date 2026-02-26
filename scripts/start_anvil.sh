#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8545}"
BASE_FEE_WEI="${BASE_FEE_WEI:-0}"
GAS_PRICE_WEI="${GAS_PRICE_WEI:-0}"

echo "Starting Anvil on ${HOST}:${PORT} (base_fee=${BASE_FEE_WEI}, gas_price=${GAS_PRICE_WEI})"
anvil --host "${HOST}" --port "${PORT}" --base-fee "${BASE_FEE_WEI}" --gas-price "${GAS_PRICE_WEI}"
