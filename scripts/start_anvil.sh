#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8545}"

echo "Starting Anvil on ${HOST}:${PORT}"
anvil --host "${HOST}" --port "${PORT}"
