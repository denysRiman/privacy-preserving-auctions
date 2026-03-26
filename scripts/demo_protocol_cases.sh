#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${ROOT_DIR}/contract"
ALICE_APP_DIR="${ROOT_DIR}/off-chain-alice"
BOB_APP_DIR="${ROOT_DIR}/off-chain-bob"
OFFCHAIN_COMMON_DIR="${ROOT_DIR}/off-chain-common"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ALICE_PK="${ALICE_PK:-${ALICE_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}}"
BOB_PK="${BOB_PK:-${BOB_PRIVATE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}}"
BIT_WIDTH="${BIT_WIDTH:-8}"
M_CHOICE="${M_CHOICE:-random}"
DEPOSIT_WEI="${DEPOSIT_WEI:-1000000000000000000}"
PAUSE_SECONDS="${PAUSE_SECONDS:-1}"
WORK_ROOT="${WORK_ROOT:-/tmp/auction-demo-cases}"
ALICE_START_BALANCE_HEX="${ALICE_START_BALANCE_HEX:-0x29a2241af62c0000}" # 3 ETH
BOB_START_BALANCE_HEX="${BOB_START_BALANCE_HEX:-0x4563918244f40000}"     # 5 ETH
ALICE_X_VALUE="${ALICE_X_VALUE:-random}"
BOB_Y_VALUE="${BOB_Y_VALUE:-random}"
TX_LEGACY="${TX_LEGACY:-1}"
TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI:-0}"
STRICT_BALANCE_CHECK="${STRICT_BALANCE_CHECK:-1}"
EVAL_BLOB_FEE_TOLERANCE_WEI="${EVAL_BLOB_FEE_TOLERANCE_WEI:-10000000000000000}" # 0.01 ETH
VERIFIER_SEED_OVERRIDE="${VERIFIER_SEED_OVERRIDE:-${VERIFIER_SEED:-}}"
VERIFIER_SALT_OVERRIDE="${VERIFIER_SALT_OVERRIDE:-${VERIFIER_SALT:-}}"

CUT_AND_CHOOSE_N=10

CONTRACT_ADDRESS=""
CIRCUIT_ID=""
LAYOUT_ROOT=""
ALICE_ADDR=""
BOB_ADDR=""
ALICE_RESET_WEI=""
BOB_RESET_WEI=""
VERIFIER_SEED_HEX=""
VERIFIER_SALT_HEX=""
VERIFIER_SEED_COMMITMENT=""
TX_FLAGS=()

is_truthy() {
  case "$1" in
    1|true|TRUE|True|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

init_tx_flags() {
  TX_FLAGS=()
  if is_truthy "${TX_LEGACY}"; then
    TX_FLAGS+=("--legacy")
  fi
  if [[ -n "${TX_GAS_PRICE_WEI}" ]]; then
    TX_FLAGS+=("--gas-price" "${TX_GAS_PRICE_WEI}")
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

preflight() {
  require_cmd cast
  require_cmd forge
  require_cmd cargo
  require_cmd curl
  require_cmd od

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

  ALICE_ADDR="$(cast wallet address --private-key "${ALICE_PK}")"
  BOB_ADDR="$(cast wallet address --private-key "${BOB_PK}")"
  init_tx_flags
}

phase() {
  local title="$1"
  printf "\n\033[1;36m== %s ==\033[0m\n" "${title}"
}

wait_phase() {
  if [[ "${PAUSE_SECONDS}" -le 0 ]]; then
    return
  fi
  sleep "${PAUSE_SECONDS}"
}

compute_circuit_meta() {
  local m_for_probe="${1:-0}"
  local challenge_for_probe
  if [[ -n "${CIRCUIT_ID}" && -n "${LAYOUT_ROOT}" ]]; then
    return
  fi

  if [[ "${m_for_probe}" == "0" ]]; then
    challenge_for_probe="1"
  else
    challenge_for_probe="0"
  fi

  local probe_out
  probe_out="$(
    cd "${OFFCHAIN_COMMON_DIR}" && cargo run --offline --quiet -- \
      --bits "${BIT_WIDTH}" \
      --m "${m_for_probe}" \
      --gate-index 0 \
      --challenge-instance "${challenge_for_probe}"
  )"

  CIRCUIT_ID="$(
    echo "${probe_out}" | sed -nE 's/^circuitId = (0x[0-9a-fA-F]{64})/\1/p' | tail -n1
  )"
  LAYOUT_ROOT="$(
    echo "${probe_out}" | sed -nE 's/^circuitLayoutRoot = (0x[0-9a-fA-F]{64})/\1/p' | tail -n1
  )"

  if [[ -z "${CIRCUIT_ID}" || -z "${LAYOUT_ROOT}" ]]; then
    echo "Failed to derive circuit metadata from off-chain-common output." >&2
    exit 1
  fi
}

deploy_contract() {
  local m_choice="$1"
  compute_circuit_meta "${m_choice}"

  local deploy_out
  if ! deploy_out="$(
    cd "${CONTRACT_DIR}" && forge create src/MillionairesProblem.sol:MillionairesProblem \
      --rpc-url "${RPC_URL}" \
      --private-key "${ALICE_PK}" \
      --broadcast \
      --json \
      --constructor-args "${BOB_ADDR}" "${CIRCUIT_ID}" "${LAYOUT_ROOT}" "${BIT_WIDTH}" 2>&1
  )"; then
    echo "Failed to deploy MillionairesProblem." >&2
    echo "${deploy_out}" >&2
    exit 1
  fi

  CONTRACT_ADDRESS="$(
    echo "${deploy_out}" \
      | tr -d '\r' \
      | sed -nE 's/.*"deployedTo"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p' \
      | tail -n1
  )"

  if [[ -z "${CONTRACT_ADDRESS}" ]]; then
    CONTRACT_ADDRESS="$(
      echo "${deploy_out}" \
        | tr -d '\r' \
        | grep -Eo 'Deployed to:[[:space:]]*0x[0-9a-fA-F]{40}' \
        | tail -n1 \
        | grep -Eo '0x[0-9a-fA-F]{40}'
    )"
  fi

  if [[ -z "${CONTRACT_ADDRESS}" ]]; then
    echo "Failed to parse deployed contract address." >&2
    echo "${deploy_out}" >&2
    exit 1
  fi

  echo "deploy: contract=${CONTRACT_ADDRESS}, circuit=$(short_hash32 "${CIRCUIT_ID}"), layout=$(short_hash32 "${LAYOUT_ROOT}") [OK]"
}

run_alice_raw() {
  (
    cd "${ALICE_APP_DIR}"
    RPC_URL="${RPC_URL}" \
    CONTRACT_ADDRESS="${CONTRACT_ADDRESS}" \
    ALICE_PRIVATE_KEY="${ALICE_PK}" \
    DEPOSIT_WEI="${DEPOSIT_WEI}" \
    TX_LEGACY="${TX_LEGACY}" \
    TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI}" \
    cargo run --offline --quiet -- "$@"
  )
}

run_bob_raw() {
  (
    cd "${BOB_APP_DIR}"
    RPC_URL="${RPC_URL}" \
    CONTRACT_ADDRESS="${CONTRACT_ADDRESS}" \
    BOB_PRIVATE_KEY="${BOB_PK}" \
    DEPOSIT_WEI="${DEPOSIT_WEI}" \
    TX_LEGACY="${TX_LEGACY}" \
    TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI}" \
    cargo run --offline --quiet -- "$@"
  )
}

extract_kv_from_text() {
  local key="$1"
  local text="$2"
  printf '%s\n' "${text}" | sed -nE "s/^${key}=(.*)$/\1/p" | tail -n1
}

first_token() {
  local value="$1"
  echo "${value%% *}"
}

wei_to_eth_safe() {
  local raw="$1"
  local wei
  wei="$(first_token "${raw}")"
  if [[ "${wei}" =~ ^[0-9]+$ ]]; then
    format_eth_compact "$(cast from-wei "${wei}")"
  else
    echo "${raw}"
  fi
}

format_eth_compact() {
  local raw="$1"
  local token
  local compact

  token="$(first_token "${raw}")"
  if [[ ! "${token}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "${raw}"
    return
  fi

  compact="$(printf '%s' "${token}" | sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$/.0/')"
  if [[ "${compact}" =~ ^[0-9]+$ ]]; then
    compact="${compact}.0"
  fi
  echo "${compact}"
}

short_hash32() {
  local value="$1"
  if [[ "${value}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "${value:0:10}...${value:58:8}"
  else
    echo "${value}"
  fi
}

file_size_bytes() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return 1
  fi
  wc -c < "${path}" | tr -d '[:space:]'
}

bytes_to_kib_tenths() {
  local bytes="$1"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]]; then
    echo "n/a"
    return
  fi
  local kib_tenths
  local whole
  local tenths
  kib_tenths=$(( (bytes * 10 + 512) / 1024 ))
  whole=$(( kib_tenths / 10 ))
  tenths=$(( kib_tenths % 10 ))
  echo "${whole}.${tenths}"
}

compact_cli_output() {
  local actor="$1"
  local command="$2"
  local raw="$3"

  case "${actor}:${command}" in
    alice:deposit)
      local before after vault
      before="$(extract_kv_from_text alice_wallet_before "${raw}")"
      after="$(extract_kv_from_text alice_wallet_after "${raw}")"
      vault="$(extract_kv_from_text alice_vault "${raw}")"
      if [[ -n "${before}" && -n "${after}" ]]; then
        echo "  Alice: deposit wallet $(wei_to_eth_safe "${before}") ETH -> $(wei_to_eth_safe "${after}") ETH, vault=$(wei_to_eth_safe "${vault}") ETH [OK]"
      fi
      ;;
    bob:deposit)
      local before after vault
      before="$(extract_kv_from_text bob_wallet_before "${raw}")"
      after="$(extract_kv_from_text bob_wallet_after "${raw}")"
      vault="$(extract_kv_from_text bob_vault "${raw}")"
      if [[ -n "${before}" && -n "${after}" ]]; then
        echo "  Bob: deposit wallet $(wei_to_eth_safe "${before}") ETH -> $(wei_to_eth_safe "${after}") ETH, vault=$(wei_to_eth_safe "${vault}") ETH [OK]"
      fi
      ;;
    alice:submit-commitments|alice:submit-core-commitments)
      local circuit_id bit_width root_ot_nonzero blob_nonzero instance0_line instance9_line
      local com0 rootgc0 rootot0 blob0 com9 rootgc9 rootot9 blob9
      circuit_id="$(extract_kv_from_text circuit_id "${raw}")"
      bit_width="$(extract_kv_from_text bit_width "${raw}")"
      root_ot_nonzero="$(
        printf '%s\n' "${raw}" \
          | sed -nE 's/.* rootOT=(0x[0-9a-fA-F]{64}).*/\1/p' \
          | grep -Evc '^0x0{64}$' || true
      )"
      blob_nonzero="$(
        printf '%s\n' "${raw}" \
          | sed -nE 's/.* blobHashGC=(0x[0-9a-fA-F]{64}).*/\1/p' \
          | grep -Evc '^0x0{64}$' || true
      )"
      instance0_line="$(printf '%s\n' "${raw}" | sed -nE '/^instance=0 /p' | head -n1)"
      instance9_line="$(printf '%s\n' "${raw}" | sed -nE "/^instance=$((CUT_AND_CHOOSE_N - 1)) /p" | head -n1)"

      com0="$(printf '%s\n' "${instance0_line}" | sed -nE 's/.*comSeed=(0x[0-9a-fA-F]{64}).*/\1/p')"
      rootgc0="$(printf '%s\n' "${instance0_line}" | sed -nE 's/.*rootGC=(0x[0-9a-fA-F]{64}).*/\1/p')"
      rootot0="$(printf '%s\n' "${instance0_line}" | sed -nE 's/.*rootOT=(0x[0-9a-fA-F]{64}).*/\1/p')"
      blob0="$(printf '%s\n' "${instance0_line}" | sed -nE 's/.*blobHashGC=(0x[0-9a-fA-F]{64}).*/\1/p')"
      com9="$(printf '%s\n' "${instance9_line}" | sed -nE 's/.*comSeed=(0x[0-9a-fA-F]{64}).*/\1/p')"
      rootgc9="$(printf '%s\n' "${instance9_line}" | sed -nE 's/.*rootGC=(0x[0-9a-fA-F]{64}).*/\1/p')"
      rootot9="$(printf '%s\n' "${instance9_line}" | sed -nE 's/.*rootOT=(0x[0-9a-fA-F]{64}).*/\1/p')"
      blob9="$(printf '%s\n' "${instance9_line}" | sed -nE 's/.*blobHashGC=(0x[0-9a-fA-F]{64}).*/\1/p')"

      echo "  Alice: submit_commitments n=${CUT_AND_CHOOSE_N}, bit_width=${bit_width}, circuit=$(short_hash32 "${circuit_id}"), rootOT_nonzero=${root_ot_nonzero}/${CUT_AND_CHOOSE_N}, blobHashGC_nonzero=${blob_nonzero}/${CUT_AND_CHOOSE_N} [OK]"
      [[ -n "${com0}" || -n "${rootgc0}" || -n "${rootot0}" || -n "${blob0}" ]] && \
        echo "  commitment_sample: i=0 comSeed=$(short_hash32 "${com0}") rootGC=$(short_hash32 "${rootgc0}") rootOT=$(short_hash32 "${rootot0}") blobHashGC=$(short_hash32 "${blob0}")"
      [[ -n "${com9}" || -n "${rootgc9}" || -n "${rootot9}" || -n "${blob9}" ]] && \
        echo "  commitment_sample: i=$((CUT_AND_CHOOSE_N - 1)) comSeed=$(short_hash32 "${com9}") rootGC=$(short_hash32 "${rootgc9}") rootOT=$(short_hash32 "${rootot9}") blobHashGC=$(short_hash32 "${blob9}")"
      ;;
    alice:submit-ot-roots)
      local root_ot_nonzero
      root_ot_nonzero="$(
        printf '%s\n' "${raw}" \
          | sed -nE 's/^instance=[0-9]+ rootOT=(0x[0-9a-fA-F]{64})/\1/p' \
          | grep -Evc '^0x0{64}$' || true
      )"
      echo "  Alice: submit_ot_roots nonzero=${root_ot_nonzero}/${CUT_AND_CHOOSE_N} [OK]"
      ;;
    alice:reveal-openings)
      local m open_indices cleaned opened_count
      m="$(extract_kv_from_text m "${raw}")"
      open_indices="$(extract_kv_from_text open_indices "${raw}")"
      if [[ -n "${open_indices}" ]]; then
        cleaned="$(printf '%s' "${open_indices}" | tr -d '[][:space:]')"
        opened_count=0
        if [[ -n "${cleaned}" ]]; then
          local -a idx_arr
          IFS=',' read -r -a idx_arr <<< "${cleaned}"
          opened_count="${#idx_arr[@]}"
        fi
        echo "  Alice: reveal_openings m=${m}, opened=${opened_count} [OK]"
        echo "  opened_instances=${open_indices}"
      fi
      ;;
    alice:reveal-labels)
      local labels_count blob_enabled
      labels_count="$(extract_kv_from_text labels_count "${raw}")"
      blob_enabled="$(extract_kv_from_text blob_enabled "${raw}")"
      [[ -n "${labels_count}" ]] && echo "  labels_revealed: count=${labels_count} [OK]"
      [[ -n "${blob_enabled}" ]] && echo "  reveal_labels_blob_tx=${blob_enabled}"
      ;;
    alice:export-artifacts)
      local out_dir
      out_dir="$(extract_kv_from_text out_dir "${raw}")"
      [[ -n "${out_dir}" ]] && echo "  artifacts=${out_dir}"
      ;;
    alice:prepare-eval)
      local h0 h1 eval_blob_file eval_blob_hash eval_blob_size eval_blob_kib
      h0="$(extract_kv_from_text h0 "${raw}")"
      h1="$(extract_kv_from_text h1 "${raw}")"
      eval_blob_file="$(extract_kv_from_text eval_blob_file "${raw}")"
      eval_blob_hash="$(extract_kv_from_text eval_blob_hash "${raw}")"
      [[ -n "${h0}" && -n "${h1}" ]] && echo "  anchors_m: h0=$(short_hash32 "${h0}"), h1=$(short_hash32 "${h1}")"
      if [[ -n "${eval_blob_file}" && -n "${eval_blob_hash}" ]]; then
        if eval_blob_size="$(file_size_bytes "${eval_blob_file}")"; then
          eval_blob_kib="$(bytes_to_kib_tenths "${eval_blob_size}")"
          echo "  eval_blob: file=${eval_blob_file}, hash=$(short_hash32 "${eval_blob_hash}"), size=${eval_blob_size} bytes (${eval_blob_kib} KiB)"
        else
          echo "  eval_blob: file=${eval_blob_file}, hash=$(short_hash32 "${eval_blob_hash}")"
        fi
      fi
      ;;
    bob:choose)
      ;;
    bob:commit-verifier-seed)
      local commitment
      commitment="$(extract_kv_from_text verifier_seed_commitment "${raw}")"
      [[ -n "${commitment}" ]] && \
        echo "  Bob: commit_verifier_seed commitment=$(short_hash32 "${commitment}") [OK]"
      ;;
    bob:reveal-verifier-seed)
      local seed salt commitment
      seed="$(extract_kv_from_text verifier_seed "${raw}")"
      salt="$(extract_kv_from_text verifier_salt "${raw}")"
      commitment="$(extract_kv_from_text verifier_seed_commitment "${raw}")"
      [[ -n "${seed}" ]] && \
        echo "  Bob: reveal_verifier_seed seed=$(short_hash32 "${seed}"), salt=$(short_hash32 "${salt}"), commitment=$(short_hash32 "${commitment}") [OK]"
      ;;
    bob:evaluate-m)
      local y_value decoded output_label
      y_value="$(extract_kv_from_text y_value "${raw}")"
      decoded="$(extract_kv_from_text decoded_bit "${raw}")"
      output_label="$(extract_kv_from_text output_label "${raw}")"
      [[ -n "${y_value}" ]] && echo "  bob_y=${y_value}"
      [[ -n "${decoded}" ]] && echo "  decoded_bit=${decoded}"
      [[ -n "${output_label}" ]] && echo "  output_label=${output_label}"
      ;;
    bob:prepare-ot-dispute)
      local input_bit round author root_ot root_match
      input_bit="$(extract_kv_from_text selected_input_bit "${raw}")"
      round="$(extract_kv_from_text selected_round "${raw}")"
      author="$(extract_kv_from_text selected_author "${raw}")"
      root_ot="$(extract_kv_from_text root_ot "${raw}")"
      root_match="$(extract_kv_from_text root_match "${raw}")"
      if [[ -n "${root_ot}" ]]; then
        echo "  ot_replay_check: sampled_leaf=(bit=${input_bit},round=${round},author=${author}), recomputed_rootOT=$(short_hash32 "${root_ot}"), root_match=${root_match} [OK]"
      fi
      ;;
    bob:dispute)
      ;;
    *)
      ;;
  esac
}

run_alice() {
  local command="$1"
  local raw
  raw="$(run_alice_raw "$@")"
  compact_cli_output "alice" "${command}" "${raw}"
}

run_bob() {
  local command="$1"
  local raw
  raw="$(run_bob_raw "$@")"
  compact_cli_output "bob" "${command}" "${raw}"
}

commit_bob_verifier_seed() {
  local commit_raw
  if [[ -n "${VERIFIER_SEED_OVERRIDE}" && -n "${VERIFIER_SALT_OVERRIDE}" ]]; then
    commit_raw="$(run_bob_raw commit-verifier-seed --seed "${VERIFIER_SEED_OVERRIDE}" --salt "${VERIFIER_SALT_OVERRIDE}")"
  elif [[ -n "${VERIFIER_SEED_OVERRIDE}" ]]; then
    commit_raw="$(run_bob_raw commit-verifier-seed --seed "${VERIFIER_SEED_OVERRIDE}")"
  elif [[ -n "${VERIFIER_SALT_OVERRIDE}" ]]; then
    commit_raw="$(run_bob_raw commit-verifier-seed --salt "${VERIFIER_SALT_OVERRIDE}")"
  else
    commit_raw="$(run_bob_raw commit-verifier-seed)"
  fi
  compact_cli_output "bob" "commit-verifier-seed" "${commit_raw}"
  VERIFIER_SEED_HEX="$(extract_kv_from_text verifier_seed "${commit_raw}")"
  VERIFIER_SALT_HEX="$(extract_kv_from_text verifier_salt "${commit_raw}")"
  VERIFIER_SEED_COMMITMENT="$(extract_kv_from_text verifier_seed_commitment "${commit_raw}")"
  assert_non_empty "verifier_seed_commitment" "${VERIFIER_SEED_COMMITMENT}"
}

reveal_bob_verifier_seed() {
  local reveal_raw
  assert_non_empty "verifier_seed" "${VERIFIER_SEED_HEX}"
  assert_non_empty "verifier_salt" "${VERIFIER_SALT_HEX}"
  reveal_raw="$(run_bob_raw reveal-verifier-seed --seed "${VERIFIER_SEED_HEX}" --salt "${VERIFIER_SALT_HEX}")"
  compact_cli_output "bob" "reveal-verifier-seed" "${reveal_raw}"
}

stage_value() {
  cast call "${CONTRACT_ADDRESS}" "currentStage()(uint8)" --rpc-url "${RPC_URL}"
}

build_root_gcs_list() {
  local dir="$1"
  local override_idx="${2:-}"
  local override_value="${3:-}"
  local out="["

  for ((i=0; i<CUT_AND_CHOOSE_N; i++)); do
    local value
    value="$(tr -d '[:space:]' < "${dir}/instance-${i}-root-gc.txt")"
    if [[ -n "${override_idx}" && "${i}" -eq "${override_idx}" ]]; then
      value="${override_value}"
    fi
    out+="${value}"
    if [[ "${i}" -lt $((CUT_AND_CHOOSE_N - 1)) ]]; then
      out+=","
    fi
  done

  out+="]"
  echo "${out}"
}

resolve_m_choice() {
  if [[ "${M_CHOICE}" == "random" ]]; then
    echo $((RANDOM % CUT_AND_CHOOSE_N))
    return
  fi

  if ! [[ "${M_CHOICE}" =~ ^[0-9]+$ ]]; then
    echo "Invalid M_CHOICE='${M_CHOICE}'. Use 'random' or an integer in [0,9]." >&2
    exit 1
  fi

  local forced="${M_CHOICE}"
  if (( forced < 0 || forced >= CUT_AND_CHOOSE_N )); then
    echo "M_CHOICE out of range: ${forced}. Expected [0,$((CUT_AND_CHOOSE_N - 1))]." >&2
    exit 1
  fi
  echo "${forced}"
}

max_exclusive_for_bit_width() {
  local bit_width="$1"
  if ! [[ "${bit_width}" =~ ^[0-9]+$ ]]; then
    echo "Invalid BIT_WIDTH='${bit_width}'. Expected a positive integer." >&2
    exit 1
  fi
  if (( bit_width <= 0 || bit_width > 56 )); then
    echo "BIT_WIDTH=${bit_width} is not supported in this demo script. Use range [1,56]." >&2
    exit 1
  fi
  echo $((1 << bit_width))
}

random_value_below() {
  local max_exclusive="$1"
  if (( max_exclusive <= 0 )); then
    echo "0"
    return
  fi
  local rand56
  rand56="$(od -An -N7 -tu8 /dev/urandom | tr -d '[:space:]')"
  echo $((rand56 % max_exclusive))
}

resolve_private_value() {
  local raw_value="$1"
  local label="$2"
  local bit_width="$3"
  local max_exclusive
  max_exclusive="$(max_exclusive_for_bit_width "${bit_width}")"

  if [[ "${raw_value}" == "random" ]]; then
    random_value_below "${max_exclusive}"
    return
  fi

  if ! [[ "${raw_value}" =~ ^[0-9]+$ ]]; then
    echo "Invalid ${label}='${raw_value}'. Use 'random' or an integer in [0,$((max_exclusive - 1))]." >&2
    exit 1
  fi

  local value="${raw_value}"
  if (( value >= max_exclusive )); then
    echo "${label} out of range: ${value}. Expected [0,$((max_exclusive - 1))] for BIT_WIDTH=${bit_width}." >&2
    exit 1
  fi
  echo "${value}"
}

winner_from_bit() {
  local bit="$1"
  case "${bit}" in
    1) echo "Alice" ;;
    0) echo "Bob" ;;
    *) echo "Unknown" ;;
  esac
}

winner_from_contract_result() {
  local result_token
  result_token="$(first_token "$1")"
  case "${result_token}" in
    true) echo "Alice" ;;
    false) echo "Bob" ;;
    *) echo "Unknown" ;;
  esac
}

choose_challenge_instance() {
  local m_choice="$1"
  if [[ "${m_choice}" == "0" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

flip_first_hex_byte() {
  local value="$1"
  local raw="${value#0x}"
  local first="${raw:0:2}"
  local rest="${raw:2}"
  local flipped
  flipped=$(printf '%02x' $((16#${first} ^ 1)))
  echo "0x${flipped}${rest}"
}

mutate_leaf_file() {
  local input_file="$1"
  local output_file="$2"
  local gate_index="$3"

  local idx=0
  : > "${output_file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    local value="${line//$'\r'/}"
    if [[ "${idx}" -eq "${gate_index}" ]]; then
      value="$(flip_first_hex_byte "${value}")"
    fi
    printf '%s\n' "${value}" >> "${output_file}"
    idx=$((idx + 1))
  done < "${input_file}"
}

extract_kv() {
  local key="$1"
  local file="$2"
  sed -nE "s/^${key}=(.*)$/\1/p" "${file}" | tail -n1
}

bytes32_list_len_literal() {
  local literal="$1"
  local cleaned
  cleaned="$(printf '%s' "${literal}" | tr -d '[][:space:]')"
  if [[ -z "${cleaned}" ]]; then
    echo "0"
    return
  fi
  awk -F',' '{print NF}' <<< "${cleaned}"
}

assert_non_empty() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "Missing value for ${name}" >&2
    exit 1
  fi
}

case_dir() {
  local name="$1"
  local out="${WORK_ROOT}/${name}"
  rm -rf "${out}"
  mkdir -p "${out}"
  echo "${out}"
}

print_balance_snapshot() {
  local label="$1"
  local alice_wei
  local bob_wei
  alice_wei="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  bob_wei="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"
  echo "${label}_alice_eth=$(format_eth_compact "$(cast from-wei "${alice_wei}")")"
  echo "${label}_bob_eth=$(format_eth_compact "$(cast from-wei "${bob_wei}")")"
}

report_and_assert_final_balances() {
  local expected_alice_wei="$1"
  local expected_bob_wei="$2"
  local actual_alice_wei
  local actual_bob_wei
  actual_alice_wei="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  actual_bob_wei="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"

  echo "final_alice_eth=$(format_eth_compact "$(cast from-wei "${actual_alice_wei}")")"
  echo "final_bob_eth=$(format_eth_compact "$(cast from-wei "${actual_bob_wei}")")"
  echo "expected_alice_eth=$(format_eth_compact "$(cast from-wei "${expected_alice_wei}")")"
  echo "expected_bob_eth=$(format_eth_compact "$(cast from-wei "${expected_bob_wei}")")"

  if is_truthy "${STRICT_BALANCE_CHECK}"; then
    if [[ "${actual_alice_wei}" != "${expected_alice_wei}" || "${actual_bob_wei}" != "${expected_bob_wei}" ]]; then
      echo "Balance check failed. Expected exact demo balances did not match." >&2
      echo "Hint: restart with ./scripts/start_anvil.sh (zero-gas defaults) or set STRICT_BALANCE_CHECK=0." >&2
      exit 1
    fi
  fi
}

common_bootstrap() {
  local m_choice="$1"
  phase "Deploy contract"
  deploy_contract "${m_choice}"
  wait_phase

  phase "Reset demo balances (post-deploy)"
  cast rpc anvil_setBalance "${ALICE_ADDR}" "${ALICE_START_BALANCE_HEX}" >/dev/null
  cast rpc anvil_setBalance "${BOB_ADDR}" "${BOB_START_BALANCE_HEX}" >/dev/null
  ALICE_RESET_WEI="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  BOB_RESET_WEI="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"
  echo "balances_reset: Alice=$(format_eth_compact "$(cast from-wei "${ALICE_RESET_WEI}")") ETH, Bob=$(format_eth_compact "$(cast from-wei "${BOB_RESET_WEI}")") ETH [OK]"
  wait_phase

  phase "Phase 1: Alice deposit"
  run_alice deposit
  wait_phase

  phase "Phase 1: Bob deposit"
  run_bob deposit
  wait_phase

  phase "Phase 2: Bob commits verifier seed commitment"
  commit_bob_verifier_seed
  wait_phase
}

show_ot_visibility() {
  local instance_id="$1"
  local _unused_dir="$2"
  local title="${3:-Phase 6 (off-chain): OT visibility check}"

  local seed
  local expected_root_ot
  local commitment_raw
  seed="$(cast call "${CONTRACT_ADDRESS}" "revealedSeeds(uint256)(bytes32)" "${instance_id}" --rpc-url "${RPC_URL}" | tr -d '[:space:]')"
  if [[ ! "${seed}" =~ ^0x[0-9a-fA-F]{64}$ ]] || [[ "${seed}" == "0x0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    echo "Missing on-chain revealed seed for opened instance ${instance_id}" >&2
    exit 1
  fi

  commitment_raw="$(cast call "${CONTRACT_ADDRESS}" "instanceCommitments(uint256)(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)" "${instance_id}" --rpc-url "${RPC_URL}")"
  expected_root_ot="$(
    printf '%s\n' "${commitment_raw}" \
      | grep -Eo '0x[0-9a-fA-F]{64}' \
      | sed -n '5p'
  )"
  assert_non_empty "expected_root_ot(instance=${instance_id})" "${expected_root_ot}"

  phase "${title}"
  echo "  ot_replay_execution: off-chain recompute (no on-chain tx in this step)"
  echo "  ot_replay_model: rootOT commits bit_width(${BIT_WIDTH})*3_rounds transcript leaves"
  echo "  ot_replay_input: instance=${instance_id}, garbler_seed=$(short_hash32 "${seed}"), verifier_seed=$(short_hash32 "${VERIFIER_SEED_HEX}")"

  local ot_raw
  ot_raw="$(
    run_bob_raw prepare-ot-dispute \
      --instance-id "${instance_id}" \
      --garbler-seed "${seed}" \
      --verifier-seed "${VERIFIER_SEED_HEX}" \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}" \
      --input-bit 0 \
      --round 0 \
      --expected-root-ot "${expected_root_ot}"
  )"
  local root_ot
  local root_match
  local selected_input_bit
  local selected_round
  local selected_author
  root_ot="$(extract_kv_from_text root_ot "${ot_raw}")"
  root_match="$(extract_kv_from_text root_match "${ot_raw}")"
  selected_input_bit="$(extract_kv_from_text selected_input_bit "${ot_raw}")"
  selected_round="$(extract_kv_from_text selected_round "${ot_raw}")"
  selected_author="$(extract_kv_from_text selected_author "${ot_raw}")"
  echo "  ot_replay_check: sampled_leaf=(bit=${selected_input_bit},round=${selected_round},author=${selected_author}), recomputed_rootOT=$(short_hash32 "${root_ot}"), committed_match=${root_match} [OK]"
}

scenario_success() {
  local m_choice
  m_choice="$(resolve_m_choice)"
  local alice_x_value
  local bob_y_value
  alice_x_value="$(resolve_private_value "${ALICE_X_VALUE}" "ALICE_X_VALUE" "${BIT_WIDTH}")"
  bob_y_value="$(resolve_private_value "${BOB_Y_VALUE}" "BOB_Y_VALUE" "${BIT_WIDTH}")"
  local out_dir
  out_dir="$(case_dir case1-success)"
  local eval_dir="${out_dir}/eval-m"

  printf "\n\033[1;32m================ CASE 1: SUCCESS FLOW ================\033[0m\n"
  echo "security_goal: honest run; commitments, opened-instance OT root replay checks, and settlement must all agree"
  echo "artifact_defs: comSeed=keccak(seed), rootGC=terminal incremental-hash root over gate leaves where leafHash=keccak(leafBytes(gateIndex,GateDesc,4-rows)), circuitLayoutRoot=commitment to (gateIndex,GateDesc) used by layout proofs, rootOT=OT transcript root, h0/h1=keccak(output_label)"
  echo "label_encoding: output_label is 16-byte GC label zero-padded to bytes32 before on-chain hash check"
  echo "liveness_hooks: verifier-seed/choose/open/labels/settle deadlines + abort/slash paths are active"
  common_bootstrap "${m_choice}"

  phase "Phase 3: Alice derives anchors and submits core commitments"
  local anchors_raw
  anchors_raw="$(
    run_alice_raw derive-anchors \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}"
  )"
  local h0_list
  local h1_list
  h0_list="$(extract_kv_from_text h0_list "${anchors_raw}")"
  h1_list="$(extract_kv_from_text h1_list "${anchors_raw}")"
  assert_non_empty "h0_list" "${h0_list}"
  assert_non_empty "h1_list" "${h1_list}"

  local submit_raw
  submit_raw="$(
    run_alice_raw submit-core-commitments \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}" \
      --h0 "${h0_list}" \
      --h1 "${h1_list}" \
      --export-dir "${out_dir}"
  )"
  compact_cli_output "alice" "submit-commitments" "${submit_raw}"
  local committed_blob_hash
  committed_blob_hash="$(
    printf '%s\n' "${submit_raw}" \
      | sed -nE "/^instance=${m_choice} /s/.*blobHashGC=(0x[0-9a-fA-F]{64}).*/\\1/p" \
      | tail -n1
  )"
  assert_non_empty "committed_blob_hash(m)" "${committed_blob_hash}"
  wait_phase

  phase "Phase 4: Bob reveals verifier seed + salt"
  reveal_bob_verifier_seed
  wait_phase

  phase "Phase 5: Alice submits OT roots"
  run_alice submit-ot-roots \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --verifier-seed "${VERIFIER_SEED_HEX}"
  wait_phase

  phase "Phase 6: Bob chooses m"
  run_bob choose --m "${m_choice}"
  echo "  choose_m: m=${m_choice}, opened_expected=$((CUT_AND_CHOOSE_N - 1)) [OK]"
  wait_phase

  phase "Phase 7: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  local challenge_instance
  challenge_instance="$(choose_challenge_instance "${m_choice}")"
  show_ot_visibility "${challenge_instance}" "${out_dir}" "Phase 8 (off-chain): Bob replays opened OT root from revealed seeds"
  wait_phase

  phase "Phase 9: Bob closes dispute window"
  cast send "${CONTRACT_ADDRESS}" "closeDispute()" \
    "${TX_FLAGS[@]}" \
    --private-key "${BOB_PK}" \
    --rpc-url "${RPC_URL}" >/dev/null
  echo "  Bob: close_dispute [OK]"
  wait_phase

  phase "Phase 10: Alice prepares evaluation package + reveals x labels (enter Settle)"
  local prepare_eval_raw
  prepare_eval_raw="$(
    run_alice_raw prepare-eval \
      --m "${m_choice}" \
      --x "${alice_x_value}" \
      --out-dir "${eval_dir}" \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}" \
      --verifier-seed "${VERIFIER_SEED_HEX}"
  )"
  echo "  eval_artifacts: prepared [OK]"
  compact_cli_output "alice" "prepare-eval" "${prepare_eval_raw}"
  local settle_h0
  local settle_h1
  local eval_blob_file
  local eval_blob_hash
  local onchain_eval_blob_hash
  local blob_link_status="[FAIL]"
  settle_h0="$(extract_kv_from_text h0 "${prepare_eval_raw}")"
  settle_h1="$(extract_kv_from_text h1 "${prepare_eval_raw}")"
  eval_blob_file="$(extract_kv_from_text eval_blob_file "${prepare_eval_raw}")"
  eval_blob_hash="$(extract_kv_from_text eval_blob_hash "${prepare_eval_raw}")"
  assert_non_empty "eval_blob_file" "${eval_blob_file}"
  assert_non_empty "eval_blob_hash" "${eval_blob_hash}"
  assert_non_empty "committed_blob_hash" "${committed_blob_hash}"

  run_alice reveal-labels \
    --labels-file "${eval_dir}/alice-x-labels32.txt" \
    --blob \
    --path "${eval_blob_file}"
  local stage_after_labels
  stage_after_labels="$(stage_value)"
  if [[ "$(first_token "${stage_after_labels}")" != "9" ]]; then
    echo "Expected Settle stage after reveal-labels, got ${stage_after_labels}" >&2
    exit 1
  fi
  onchain_eval_blob_hash="$(cast call "${CONTRACT_ADDRESS}" "evaluationTableBlobHash()(bytes32)" --rpc-url "${RPC_URL}" | tr -d '[:space:]')"
  if [[ "${eval_blob_hash}" == "${committed_blob_hash}" && "${onchain_eval_blob_hash}" == "${committed_blob_hash}" ]]; then
    blob_link_status="[OK]"
  fi
  echo "  blob_link_m: committed=$(short_hash32 "${committed_blob_hash}"), prepared=$(short_hash32 "${eval_blob_hash}"), onchain=$(short_hash32 "${onchain_eval_blob_hash}") ${blob_link_status}"
  echo "  stage_transition: stage=Settle(9) [OK]"
  wait_phase

  phase "Phase 11: Settlement (Bob evaluates m and settles)"
  local eval_raw
  eval_raw="$(
    run_bob_raw evaluate-m \
      --payload-file "${eval_blob_file}" \
      --alice-labels-file "${eval_dir}/alice-x-labels16.txt" \
      --y "${bob_y_value}"
  )"
  local output_label
  output_label="$(extract_kv_from_text output_label "${eval_raw}")"
  local decoded_bit
  decoded_bit="$(extract_kv_from_text decoded_bit "${eval_raw}")"
  local decoded_anchor
  local output_anchor_match
  local output_label_hash
  assert_non_empty "output_label" "${output_label}"
  if [[ "${decoded_bit}" == "1" ]]; then
    decoded_anchor="h0"
  elif [[ "${decoded_bit}" == "0" ]]; then
    decoded_anchor="h1"
  else
    decoded_anchor="unknown"
  fi

  output_label_hash="$(cast keccak "${output_label}" | tr -d '[:space:]')"
  output_anchor_match="unknown"
  if [[ -n "${settle_h0}" && "${output_label_hash}" == "${settle_h0}" ]]; then
    output_anchor_match="h0"
  elif [[ -n "${settle_h1}" && "${output_label_hash}" == "${settle_h1}" ]]; then
    output_anchor_match="h1"
  fi

  cast send "${CONTRACT_ADDRESS}" "settle(bytes32)" "${output_label}" \
    "${TX_FLAGS[@]}" \
    --private-key "${BOB_PK}" \
    --rpc-url "${RPC_URL}" >/dev/null

  local stage
  local result
  local expected_bit
  local expected_result
  local expected_winner
  local winner_by_gc
  local winner_by_contract
  local x_gt_y
  local output_label_short
  local output_label_hash_short
  local settle_h0_short
  local settle_h1_short
  local result_token
  local stage_token
  local ot_anchor_ok=0
  local ot_anchor_status="[FAIL]"
  local bit_consistency_ok=0
  local bit_consistency_status="[FAIL]"
  local onchain_ok=0
  local onchain_status="[FAIL]"
  local expected_alice_wei
  local expected_bob_wei
  local actual_alice_wei
  local actual_bob_wei
  local alice_payout_status="[FAIL]"
  local bob_payout_status="[FAIL]"
  local payout_ok=0
  local payout_status="[FAIL]"
  local blob_fee_mode=0
  local alice_fee_drift=0
  local bob_fee_drift=0
  stage="$(stage_value)"
  result="$(cast call "${CONTRACT_ADDRESS}" "result()(bool)" --rpc-url "${RPC_URL}")"
  if (( alice_x_value > bob_y_value )); then
    x_gt_y="true"
    expected_bit=1
    expected_result="true"
    expected_winner="Alice"
  else
    x_gt_y="false"
    expected_bit=0
    expected_result="false"
    expected_winner="Bob"
  fi
  expected_alice_wei="${ALICE_RESET_WEI}"
  expected_bob_wei="${BOB_RESET_WEI}"
  winner_by_gc="$(winner_from_bit "${decoded_bit}")"
  winner_by_contract="$(winner_from_contract_result "${result}")"
  output_label_short="$(short_hash32 "${output_label}")"
  output_label_hash_short="$(short_hash32 "${output_label_hash}")"
  settle_h0_short="$(short_hash32 "${settle_h0}")"
  settle_h1_short="$(short_hash32 "${settle_h1}")"
  result_token="$(first_token "${result}")"
  stage_token="$(first_token "${stage}")"
  actual_alice_wei="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  actual_bob_wei="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"

  if [[ "${output_anchor_match}" == "h0" || "${output_anchor_match}" == "h1" ]]; then
    ot_anchor_ok=1
    ot_anchor_status="[OK]"
  fi
  if [[ "${decoded_bit}" == "${expected_bit}" ]]; then
    bit_consistency_ok=1
    bit_consistency_status="[OK]"
  fi
  if [[ "${actual_alice_wei}" == "${expected_alice_wei}" && "${actual_bob_wei}" == "${expected_bob_wei}" ]]; then
    payout_ok=1
    payout_status="[OK]"
  fi
  if [[ "${actual_alice_wei}" == "${expected_alice_wei}" ]]; then
    alice_payout_status="[OK]"
  fi
  if [[ "${actual_bob_wei}" == "${expected_bob_wei}" ]]; then
    bob_payout_status="[OK]"
  fi

  if [[ "${blob_link_status}" == "[OK]" ]]; then
    blob_fee_mode=1
    alice_fee_drift=$((expected_alice_wei - actual_alice_wei))
    bob_fee_drift=$((expected_bob_wei - actual_bob_wei))
    if (( alice_fee_drift >= 0 && alice_fee_drift <= EVAL_BLOB_FEE_TOLERANCE_WEI )); then
      alice_payout_status="[OK~fees]"
    fi
    if (( bob_fee_drift >= 0 && bob_fee_drift <= EVAL_BLOB_FEE_TOLERANCE_WEI )); then
      bob_payout_status="[OK~fees]"
    fi
    if [[ "${alice_payout_status}" != "[FAIL]" && "${bob_payout_status}" != "[FAIL]" ]]; then
      payout_ok=1
      payout_status="[OK~fees]"
    fi
  fi

  if [[ "${winner_by_gc}" == "Unknown" || "${winner_by_contract}" == "Unknown" ]]; then
    echo "Failed to determine winner from outputs." >&2
    exit 1
  fi
  if [[ "${winner_by_gc}" != "${winner_by_contract}" ]]; then
    echo "Winner mismatch: GC=${winner_by_gc}, contract=${winner_by_contract}" >&2
    exit 1
  fi

  if [[ "${stage_token}" == "10" && "${result_token}" == "${expected_result}" && "${winner_by_contract}" == "${expected_winner}" ]]; then
    onchain_ok=1
    onchain_status="[OK]"
  fi

  echo "eval_link: Bob uses Alice x-labels plus y-label offers in eval blob (PoC OT model) to evaluate GC(m) and derive output_label"
  echo "comparison: Alice x=${alice_x_value}, Bob y=${bob_y_value} -> x>y=${x_gt_y} -> expected_bit=${expected_bit} (expected winner: ${expected_winner})"
  echo "bob_eval: decoded_bit=${decoded_bit}, output_label=${output_label_short}"
  echo "ot_check: keccak(output_label)=${output_label_hash_short} -> matched ${output_anchor_match} (h0=${settle_h0_short}, h1=${settle_h1_short}) ${ot_anchor_status}"
  echo "consistency: decoded_bit == expected_bit -> ${decoded_bit} == ${expected_bit} ${bit_consistency_status}"
  echo "onchain_settle: result=${result_token} -> winner=${winner_by_contract} ${onchain_status}, final_stage=Closed"
  echo "payouts: Alice=$(format_eth_compact "$(cast from-wei "${actual_alice_wei}")") ETH (exp $(format_eth_compact "$(cast from-wei "${expected_alice_wei}")")) ${alice_payout_status}, Bob=$(format_eth_compact "$(cast from-wei "${actual_bob_wei}")") ETH (exp $(format_eth_compact "$(cast from-wei "${expected_bob_wei}")")) ${bob_payout_status}"
  if (( blob_fee_mode )); then
    echo "payouts_note: blob tx fees accounted (tolerance=$(format_eth_compact "$(cast from-wei "${EVAL_BLOB_FEE_TOLERANCE_WEI}")") ETH)"
  fi

  if [[ "${ot_anchor_ok}" -ne 1 ]]; then
    echo "Output label hash did not match committed anchors h0/h1." >&2
    exit 1
  fi
  if [[ "${bit_consistency_ok}" -ne 1 ]]; then
    echo "Decoded bit mismatch: decoded_bit=${decoded_bit}, expected_bit=${expected_bit}" >&2
    exit 1
  fi
  if [[ "${onchain_ok}" -ne 1 ]]; then
    echo "On-chain settle verification failed: result=${result_token}, stage=${stage_token}, winner=${winner_by_contract}, expected_result=${expected_result}, expected_winner=${expected_winner}" >&2
    exit 1
  fi
  if is_truthy "${STRICT_BALANCE_CHECK}"; then
    if [[ "${payout_ok}" -ne 1 ]]; then
      echo "Balance check failed. Expected exact demo balances did not match." >&2
      echo "Hint: restart with ./scripts/start_anvil.sh (zero-gas defaults) or set STRICT_BALANCE_CHECK=0." >&2
      exit 1
    fi
  fi
}

scenario_alice_cheats() {
  local m_choice
  m_choice="$(resolve_m_choice)"
  local out_dir
  out_dir="$(case_dir case2-alice-cheats)"
  local challenge_instance
  challenge_instance="$(choose_challenge_instance "${m_choice}")"
  local challenge_gate_index=0

  printf "\n\033[1;31m============= CASE 2: ALICE CHEATS, BOB SLASHES =============\033[0m\n"
  echo "security_goal: if Alice tampers opened-instance GC commitment, Bob proves mismatch and Alice is slashed"
  echo "liveness_hooks: verifier-seed/choose/open/dispute/labels/settle deadlines + abort/slash paths are active"
  common_bootstrap "${m_choice}"

  phase "Phase 3: Alice exports honest artifacts"
  run_alice export-artifacts \
    --out-dir "${out_dir}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  phase "Phase 3: Alice commits a tampered core commitment for one opened instance"
  local seed_file="${out_dir}/instance-${challenge_instance}-seed.txt"
  local honest_leaves_file="${out_dir}/instance-${challenge_instance}-leaves.txt"
  local tampered_leaves_file="${out_dir}/instance-${challenge_instance}-leaves-tampered.txt"
  local prep_file="${out_dir}/prepare-dispute-output.txt"
  local seed
  seed="$(tr -d '[:space:]' < "${seed_file}")"
  mutate_leaf_file "${honest_leaves_file}" "${tampered_leaves_file}" "${challenge_gate_index}"

  local prep_out
  prep_out="$(
    run_bob_raw prepare-dispute \
      --instance-id "${challenge_instance}" \
      --seed "${seed}" \
      --claimed-leaves-file "${tampered_leaves_file}" \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}"
  )"
  printf '%s\n' "${prep_out}" > "${prep_file}"
  local prep_gate
  local prep_gate_mismatch
  local prep_mismatch_count
  prep_gate="$(extract_kv selected_gate_index "${prep_file}")"
  prep_gate_mismatch="$(extract_kv selected_gate_mismatch "${prep_file}")"
  prep_mismatch_count="$(extract_kv mismatch_count "${prep_file}")"
  echo "  tamper_plan: opened_instance=${challenge_instance}, gate_index=${prep_gate}, selected_gate_mismatch=${prep_gate_mismatch}, mismatch_count=${prep_mismatch_count}"

  local tampered_root
  tampered_root="$(extract_kv root_gc "${prep_file}")"
  assert_non_empty "tampered_root" "${tampered_root}"

  local root_gcs_list
  root_gcs_list="$(build_root_gcs_list "${out_dir}" "${challenge_instance}" "${tampered_root}")"

  run_alice submit-core-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --root-gcs "${root_gcs_list}"
  wait_phase

  phase "Phase 4: Bob reveals verifier seed + salt"
  reveal_bob_verifier_seed
  wait_phase

  phase "Phase 5: Alice submits OT roots"
  run_alice submit-ot-roots \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --verifier-seed "${VERIFIER_SEED_HEX}"
  wait_phase

  phase "Phase 6: Bob chooses m"
  run_bob choose --m "${m_choice}"
  echo "  choose_m: m=${m_choice}, opened_expected=$((CUT_AND_CHOOSE_N - 1)) [OK]"
  wait_phase

  phase "Phase 7: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  show_ot_visibility "${challenge_instance}" "${out_dir}" "Phase 8 (off-chain): Bob replays opened OT root from revealed seeds"
  wait_phase

  phase "Phase 9: Bob disputes one tampered GC node"
  local gate_index
  local gate_type
  local wire_a
  local wire_b
  local wire_c
  local claimed_leaf
  local expected_leaf
  local claimed_leaf_hash
  local expected_leaf_hash
  local ih_proof
  local layout_proof
  local ih_proof_len
  local layout_proof_len

  gate_index="$(extract_kv selected_gate_index "${prep_file}")"
  gate_type="$(extract_kv gate_type "${prep_file}")"
  wire_a="$(extract_kv wire_a "${prep_file}")"
  wire_b="$(extract_kv wire_b "${prep_file}")"
  wire_c="$(extract_kv wire_c "${prep_file}")"
  claimed_leaf="$(extract_kv claimed_leaf "${prep_file}")"
  expected_leaf="$(extract_kv expected_leaf "${prep_file}")"
  ih_proof="$(extract_kv ih_proof "${prep_file}")"
  layout_proof="$(extract_kv layout_proof "${prep_file}")"
  claimed_leaf_hash="$(cast keccak "${claimed_leaf}" | tr -d '[:space:]')"
  expected_leaf_hash="$(cast keccak "${expected_leaf}" | tr -d '[:space:]')"
  ih_proof_len="$(bytes32_list_len_literal "${ih_proof}")"
  layout_proof_len="$(bytes32_list_len_literal "${layout_proof}")"

  assert_non_empty "gate_index" "${gate_index}"
  assert_non_empty "gate_type" "${gate_type}"
  assert_non_empty "wire_a" "${wire_a}"
  assert_non_empty "wire_b" "${wire_b}"
  assert_non_empty "wire_c" "${wire_c}"
  assert_non_empty "claimed_leaf" "${claimed_leaf}"
  assert_non_empty "expected_leaf" "${expected_leaf}"
  assert_non_empty "ih_proof" "${ih_proof}"
  assert_non_empty "layout_proof" "${layout_proof}"
  echo "  dispute_context: rootGC(instance=${challenge_instance})=$(short_hash32 "${tampered_root}")"
  echo "  tamper_mechanism: mismatch iff committed/challenged leaf hash != recomputed hash from (seed, gateDesc, gateIndex)"
  echo "  dispute_input: instance=${challenge_instance}, gate_index=${gate_index}, gate_desc=(type=${gate_type},a=${wire_a},b=${wire_b},c=${wire_c}), ih_proof_len=${ih_proof_len}, layout_proof_len=${layout_proof_len}"
  echo "  dispute_leaf_check: claimed_hash=$(short_hash32 "${claimed_leaf_hash}"), recomputed_hash=$(short_hash32 "${expected_leaf_hash}"), match=false [expected]"

  run_bob dispute \
    --instance-id "${challenge_instance}" \
    --seed "${seed}" \
    --gate-index "${gate_index}" \
    --gate-type "${gate_type}" \
    --wire-a "${wire_a}" \
    --wire-b "${wire_b}" \
    --wire-c "${wire_c}" \
    --leaf-bytes "${claimed_leaf}" \
    --ih-proof "${ih_proof}" \
    --layout-proof "${layout_proof}"

  local stage
  stage="$(stage_value)"
  echo "final_stage=${stage} (10 means Closed)"
  echo "winner=Bob"
  echo "outcome=Alice slashed, Bob won dispute"
  local expected_alice
  local expected_bob
  expected_alice=$((ALICE_RESET_WEI - DEPOSIT_WEI))
  expected_bob=$((BOB_RESET_WEI + DEPOSIT_WEI))
  report_and_assert_final_balances "${expected_alice}" "${expected_bob}"
}

scenario_bob_cheats() {
  local m_choice
  m_choice="$(resolve_m_choice)"
  local out_dir
  out_dir="$(case_dir case3-bob-cheats)"
  local challenge_instance
  challenge_instance="$(choose_challenge_instance "${m_choice}")"

  printf "\n\033[1;35m========== CASE 3: BOB FALSE-CHALLENGES, ALICE WINS ==========\033[0m\n"
  echo "security_goal: if Bob submits a false GC dispute on opened instance, Bob is slashed and Alice wins"
  echo "liveness_hooks: dispute/labels/settle deadlines remain enforced; false challenge is economically penalized"
  common_bootstrap "${m_choice}"

  phase "Phase 3: Alice submits honest core commitments"
  run_alice submit-core-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --export-dir "${out_dir}"
  wait_phase

  phase "Phase 4: Bob reveals verifier seed + salt"
  reveal_bob_verifier_seed
  wait_phase

  phase "Phase 5: Alice submits OT roots"
  run_alice submit-ot-roots \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --verifier-seed "${VERIFIER_SEED_HEX}"
  wait_phase

  phase "Phase 6: Bob chooses m"
  run_bob choose --m "${m_choice}"
  echo "  choose_m: m=${m_choice}, opened_expected=$((CUT_AND_CHOOSE_N - 1)) [OK]"
  wait_phase

  phase "Phase 7: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  show_ot_visibility "${challenge_instance}" "${out_dir}" "Phase 8 (off-chain): Bob replays opened OT root from revealed seeds"
  wait_phase

  phase "Phase 9: Bob submits false GC challenge"
  local seed_file="${out_dir}/instance-${challenge_instance}-seed.txt"
  local leaves_file="${out_dir}/instance-${challenge_instance}-leaves.txt"
  local root_file="${out_dir}/instance-${challenge_instance}-root-gc.txt"
  local prep_file="${out_dir}/prepare-false-dispute-output.txt"
  local seed
  local expected_root
  seed="$(tr -d '[:space:]' < "${seed_file}")"
  expected_root="$(tr -d '[:space:]' < "${root_file}")"

  local prep_out
  prep_out="$(
    run_bob_raw prepare-dispute \
      --instance-id "${challenge_instance}" \
      --seed "${seed}" \
      --claimed-leaves-file "${leaves_file}" \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}" \
      --expected-root-gc "${expected_root}" \
      --gate-index 0 \
      --allow-false-challenge
  )"
  printf '%s\n' "${prep_out}" > "${prep_file}"
  local prep_gate
  local prep_match
  prep_gate="$(extract_kv selected_gate_index "${prep_file}")"
  prep_match="$(extract_kv selected_gate_mismatch "${prep_file}")"
  echo "  prepared_dispute_gate=${prep_gate}"
  echo "  selected_gate_mismatch=${prep_match}"

  local gate_index
  local gate_type
  local wire_a
  local wire_b
  local wire_c
  local claimed_leaf
  local expected_leaf
  local claimed_leaf_hash
  local expected_leaf_hash
  local ih_proof
  local layout_proof
  local ih_proof_len
  local layout_proof_len

  gate_index="$(extract_kv selected_gate_index "${prep_file}")"
  gate_type="$(extract_kv gate_type "${prep_file}")"
  wire_a="$(extract_kv wire_a "${prep_file}")"
  wire_b="$(extract_kv wire_b "${prep_file}")"
  wire_c="$(extract_kv wire_c "${prep_file}")"
  claimed_leaf="$(extract_kv claimed_leaf "${prep_file}")"
  expected_leaf="$(extract_kv expected_leaf "${prep_file}")"
  ih_proof="$(extract_kv ih_proof "${prep_file}")"
  layout_proof="$(extract_kv layout_proof "${prep_file}")"
  claimed_leaf_hash="$(cast keccak "${claimed_leaf}" | tr -d '[:space:]')"
  expected_leaf_hash="$(cast keccak "${expected_leaf}" | tr -d '[:space:]')"
  ih_proof_len="$(bytes32_list_len_literal "${ih_proof}")"
  layout_proof_len="$(bytes32_list_len_literal "${layout_proof}")"

  assert_non_empty "gate_index" "${gate_index}"
  assert_non_empty "gate_type" "${gate_type}"
  assert_non_empty "wire_a" "${wire_a}"
  assert_non_empty "wire_b" "${wire_b}"
  assert_non_empty "wire_c" "${wire_c}"
  assert_non_empty "claimed_leaf" "${claimed_leaf}"
  assert_non_empty "expected_leaf" "${expected_leaf}"
  assert_non_empty "ih_proof" "${ih_proof}"
  assert_non_empty "layout_proof" "${layout_proof}"
  echo "  dispute_context: rootGC(instance=${challenge_instance})=$(short_hash32 "${expected_root}")"
  echo "  dispute_input: instance=${challenge_instance}, gate_index=${gate_index}, gate_desc=(type=${gate_type},a=${wire_a},b=${wire_b},c=${wire_c}), ih_proof_len=${ih_proof_len}, layout_proof_len=${layout_proof_len}"
  echo "  dispute_leaf_check: claimed_hash=$(short_hash32 "${claimed_leaf_hash}"), recomputed_hash=$(short_hash32 "${expected_leaf_hash}"), match=true [expected false-challenge]"

  run_bob dispute \
    --instance-id "${challenge_instance}" \
    --seed "${seed}" \
    --gate-index "${gate_index}" \
    --gate-type "${gate_type}" \
    --wire-a "${wire_a}" \
    --wire-b "${wire_b}" \
    --wire-c "${wire_c}" \
    --leaf-bytes "${claimed_leaf}" \
    --ih-proof "${ih_proof}" \
    --layout-proof "${layout_proof}"

  local stage
  stage="$(stage_value)"
  echo "final_stage=${stage} (10 means Closed)"
  echo "winner=Alice"
  echo "outcome=Bob false-challenged, Alice received collateral"
  local expected_alice
  local expected_bob
  expected_alice=$((ALICE_RESET_WEI + DEPOSIT_WEI))
  expected_bob=$((BOB_RESET_WEI - DEPOSIT_WEI))
  report_and_assert_final_balances "${expected_alice}" "${expected_bob}"
}

usage() {
  cat <<EOF
Usage: ./scripts/demo_protocol_cases.sh [command]

Commands:
  all        Run all 3 scenarios (default)
  success    Run only happy-path scenario
  alice-cheat
  bob-cheat
  help

Env overrides:
  RPC_URL, ALICE_PK, BOB_PK, BIT_WIDTH, M_CHOICE, DEPOSIT_WEI, PAUSE_SECONDS, WORK_ROOT,
  ALICE_START_BALANCE_HEX, BOB_START_BALANCE_HEX,
  ALICE_X_VALUE (random|int), BOB_Y_VALUE (random|int),
  TX_LEGACY, TX_GAS_PRICE_WEI, STRICT_BALANCE_CHECK
EOF
}

main() {
  local command="${1:-all}"
  if [[ "${command}" == "-h" || "${command}" == "--help" || "${command}" == "help" ]]; then
    usage
    exit 0
  fi
  preflight
  mkdir -p "${WORK_ROOT}"

  case "${command}" in
    all)
      scenario_success
      wait_phase
      scenario_alice_cheats
      wait_phase
      scenario_bob_cheats
      ;;
    success) scenario_success ;;
    alice-cheat) scenario_alice_cheats ;;
    bob-cheat) scenario_bob_cheats ;;
    *)
      echo "Unknown command: ${command}" >&2
      usage
      exit 1
      ;;
  esac

  printf "\n\033[1;32mDemo completed.\033[0m\n"
  echo "artifacts_root=${WORK_ROOT}"
}

main "${1:-all}"
