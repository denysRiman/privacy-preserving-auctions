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
PAUSE_SECONDS="${PAUSE_SECONDS:-5}"
WORK_ROOT="${WORK_ROOT:-/tmp/auction-demo-cases}"
ALICE_START_BALANCE_HEX="${ALICE_START_BALANCE_HEX:-0x29a2241af62c0000}" # 3 ETH
BOB_START_BALANCE_HEX="${BOB_START_BALANCE_HEX:-0x4563918244f40000}"     # 5 ETH
ALICE_X_VALUE="${ALICE_X_VALUE:-random}"
BOB_Y_VALUE="${BOB_Y_VALUE:-random}"
TX_LEGACY="${TX_LEGACY:-1}"
TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI:-0}"
STRICT_BALANCE_CHECK="${STRICT_BALANCE_CHECK:-1}"

CUT_AND_CHOOSE_N=10

CONTRACT_ADDRESS=""
CIRCUIT_ID=""
LAYOUT_ROOT=""
ALICE_ADDR=""
BOB_ADDR=""
ALICE_RESET_WEI=""
BOB_RESET_WEI=""
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
  echo "  waiting ${PAUSE_SECONDS}s..."
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
  deploy_out="$(
    cd "${CONTRACT_DIR}" && forge create src/MillionairesProblem.sol:MillionairesProblem \
      --rpc-url "${RPC_URL}" \
      --private-key "${ALICE_PK}" \
      --broadcast \
      --json \
      --constructor-args "${BOB_ADDR}" "${CIRCUIT_ID}" "${LAYOUT_ROOT}" 2>&1
  )"

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

  echo "contract_address=${CONTRACT_ADDRESS}"
  echo "circuit_id=${CIRCUIT_ID}"
  echo "layout_root=${LAYOUT_ROOT}"
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
    cast from-wei "${wei}"
  else
    echo "${raw}"
  fi
}

compact_cli_output() {
  local actor="$1"
  local command="$2"
  local raw="$3"

  case "${actor}:${command}" in
    alice:deposit)
      local tx before after vault
      tx="$(extract_kv_from_text deposit_tx_hash "${raw}")"
      before="$(extract_kv_from_text alice_wallet_before "${raw}")"
      after="$(extract_kv_from_text alice_wallet_after "${raw}")"
      vault="$(extract_kv_from_text alice_vault "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
      [[ -n "${before}" && -n "${after}" ]] && echo "  alice_wallet: $(wei_to_eth_safe "${before}") ETH -> $(wei_to_eth_safe "${after}") ETH"
      [[ -n "${vault}" ]] && echo "  alice_vault: $(wei_to_eth_safe "${vault}") ETH"
      ;;
    bob:deposit)
      local tx before after vault
      tx="$(extract_kv_from_text deposit_tx_hash "${raw}")"
      before="$(extract_kv_from_text bob_wallet_before "${raw}")"
      after="$(extract_kv_from_text bob_wallet_after "${raw}")"
      vault="$(extract_kv_from_text bob_vault "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
      [[ -n "${before}" && -n "${after}" ]] && echo "  bob_wallet: $(wei_to_eth_safe "${before}") ETH -> $(wei_to_eth_safe "${after}") ETH"
      [[ -n "${vault}" ]] && echo "  bob_vault: $(wei_to_eth_safe "${vault}") ETH"
      ;;
    alice:submit-commitments)
      local tx
      tx="$(extract_kv_from_text submit_commitments_tx_hash "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
      echo "  commitments_submitted=${CUT_AND_CHOOSE_N}"
      ;;
    alice:reveal-openings)
      local tx
      tx="$(extract_kv_from_text reveal_openings_tx_hash "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
      ;;
    alice:reveal-labels)
      local tx labels_count
      tx="$(extract_kv_from_text reveal_labels_tx_hash "${raw}")"
      labels_count="$(extract_kv_from_text labels_count "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
      [[ -n "${labels_count}" ]] && echo "  labels_count=${labels_count}"
      ;;
    alice:export-artifacts)
      local out_dir
      out_dir="$(extract_kv_from_text out_dir "${raw}")"
      [[ -n "${out_dir}" ]] && echo "  artifacts=${out_dir}"
      ;;
    alice:prepare-eval)
      local eval_dir x_value h0 h1
      eval_dir="$(extract_kv_from_text eval_dir "${raw}")"
      x_value="$(extract_kv_from_text x_value "${raw}")"
      h0="$(extract_kv_from_text h0 "${raw}")"
      h1="$(extract_kv_from_text h1 "${raw}")"
      [[ -n "${eval_dir}" ]] && echo "  eval_dir=${eval_dir}"
      [[ -n "${x_value}" ]] && echo "  alice_x=${x_value}"
      [[ -n "${h0}" ]] && echo "  h0(m)=${h0}"
      [[ -n "${h1}" ]] && echo "  h1(m)=${h1}"
      ;;
    bob:choose)
      local tx
      tx="$(extract_kv_from_text choose_tx_hash "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
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
    bob:dispute)
      local tx
      tx="$(extract_kv_from_text dispute_tx_hash "${raw}")"
      [[ -n "${tx}" ]] && echo "  tx=${tx}"
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
  echo "${label}_alice_wei=${alice_wei}"
  echo "${label}_alice_eth=$(cast from-wei "${alice_wei}")"
  echo "${label}_bob_wei=${bob_wei}"
  echo "${label}_bob_eth=$(cast from-wei "${bob_wei}")"
}

report_and_assert_final_balances() {
  local expected_alice_wei="$1"
  local expected_bob_wei="$2"
  local actual_alice_wei
  local actual_bob_wei
  actual_alice_wei="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  actual_bob_wei="$(cast balance "${BOB_ADDR}" --rpc-url "${RPC_URL}")"

  echo "final_alice_wei=${actual_alice_wei}"
  echo "final_alice_eth=$(cast from-wei "${actual_alice_wei}")"
  echo "final_bob_wei=${actual_bob_wei}"
  echo "final_bob_eth=$(cast from-wei "${actual_bob_wei}")"
  echo "expected_alice_wei=${expected_alice_wei}"
  echo "expected_alice_eth=$(cast from-wei "${expected_alice_wei}")"
  echo "expected_bob_wei=${expected_bob_wei}"
  echo "expected_bob_eth=$(cast from-wei "${expected_bob_wei}")"

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
  print_balance_snapshot "start"
  wait_phase

  phase "Phase 1: Alice deposit"
  run_alice deposit
  wait_phase

  phase "Phase 1: Bob deposit"
  run_bob deposit
  wait_phase
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
  echo "bob_m_choice=${m_choice}"
  echo "alice_x=${alice_x_value}"
  echo "bob_y=${bob_y_value}"
  common_bootstrap "${m_choice}"

  phase "Phase 2: derive output anchors + submit commitments"
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

  run_alice submit-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --h0 "${h0_list}" \
    --h1 "${h1_list}" \
    --export-dir "${out_dir}"
  wait_phase

  phase "Phase 3: Bob chooses m"
  run_bob choose --m "${m_choice}"
  wait_phase

  phase "Phase 4: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  phase "Phase 5: Bob closes dispute window"
  cast send "${CONTRACT_ADDRESS}" "closeDispute()" \
    "${TX_FLAGS[@]}" \
    --private-key "${BOB_PK}" \
    --rpc-url "${RPC_URL}" >/dev/null
  echo "closeDispute sent"
  wait_phase

  phase "Phase 6: Alice prepares evaluation package (OT-simulated) + reveals x labels"
  run_alice prepare-eval \
    --m "${m_choice}" \
    --x "${alice_x_value}" \
    --out-dir "${eval_dir}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"

  run_alice reveal-labels --labels-file "${eval_dir}/alice-x-labels32.txt"
  wait_phase

  phase "Phase 7: Bob evaluates GC_m with y (OT-simulated) and submits output label"
  local eval_raw
  eval_raw="$(
    run_bob_raw evaluate-m \
      --eval-dir "${eval_dir}" \
      --y "${bob_y_value}"
  )"
  compact_cli_output "bob" "evaluate-m" "${eval_raw}"
  local output_label
  output_label="$(extract_kv_from_text output_label "${eval_raw}")"
  local decoded_bit
  decoded_bit="$(extract_kv_from_text decoded_bit "${eval_raw}")"
  assert_non_empty "output_label" "${output_label}"

  cast send "${CONTRACT_ADDRESS}" "settle(bytes32)" "${output_label}" \
    "${TX_FLAGS[@]}" \
    --private-key "${BOB_PK}" \
    --rpc-url "${RPC_URL}" >/dev/null

  local stage
  local result
  local expected_bit
  local winner_by_gc
  local winner_by_contract
  stage="$(stage_value)"
  result="$(cast call "${CONTRACT_ADDRESS}" "result()(bool)" --rpc-url "${RPC_URL}")"
  if (( alice_x_value > bob_y_value )); then
    expected_bit=1
  else
    expected_bit=0
  fi
  winner_by_gc="$(winner_from_bit "${decoded_bit}")"
  winner_by_contract="$(winner_from_contract_result "${result}")"

  if [[ "${winner_by_gc}" == "Unknown" || "${winner_by_contract}" == "Unknown" ]]; then
    echo "Failed to determine winner from outputs." >&2
    exit 1
  fi
  if [[ "${winner_by_gc}" != "${winner_by_contract}" ]]; then
    echo "Winner mismatch: GC=${winner_by_gc}, contract=${winner_by_contract}" >&2
    exit 1
  fi

  echo "final_stage=${stage} (7 means Closed)"
  echo "input_x=${alice_x_value}"
  echo "input_y=${bob_y_value}"
  echo "decoded_bit=${decoded_bit} (from Bob GC evaluation)"
  echo "expected_bit=${expected_bit} (x>y)"
  echo "result=${result} (contract bool: h0-match => true)"
  echo "winner=${winner_by_contract}"
  report_and_assert_final_balances "${ALICE_RESET_WEI}" "${BOB_RESET_WEI}"
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
  echo "bob_m_choice=${m_choice}"
  common_bootstrap "${m_choice}"

  phase "Phase 2: Alice exports honest artifacts"
  run_alice export-artifacts \
    --out-dir "${out_dir}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  phase "Phase 2: Alice commits a tampered rootGC for one opened instance"
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
  local prep_mismatch_count
  prep_gate="$(extract_kv selected_gate_index "${prep_file}")"
  prep_mismatch_count="$(extract_kv mismatch_count "${prep_file}")"
  echo "  prepared_dispute_gate=${prep_gate}"
  echo "  mismatch_count=${prep_mismatch_count}"

  local tampered_root
  tampered_root="$(extract_kv root_gc "${prep_file}")"
  assert_non_empty "tampered_root" "${tampered_root}"

  local root_gcs_list
  root_gcs_list="$(build_root_gcs_list "${out_dir}" "${challenge_instance}" "${tampered_root}")"

  run_alice submit-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --root-gcs "${root_gcs_list}"
  wait_phase

  phase "Phase 3: Bob chooses m"
  run_bob choose --m "${m_choice}"
  wait_phase

  phase "Phase 4: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  phase "Phase 5: Bob disputes one tampered node"
  local gate_index
  local gate_type
  local wire_a
  local wire_b
  local wire_c
  local claimed_leaf
  local ih_proof
  local layout_proof

  gate_index="$(extract_kv selected_gate_index "${prep_file}")"
  gate_type="$(extract_kv gate_type "${prep_file}")"
  wire_a="$(extract_kv wire_a "${prep_file}")"
  wire_b="$(extract_kv wire_b "${prep_file}")"
  wire_c="$(extract_kv wire_c "${prep_file}")"
  claimed_leaf="$(extract_kv claimed_leaf "${prep_file}")"
  ih_proof="$(extract_kv ih_proof "${prep_file}")"
  layout_proof="$(extract_kv layout_proof "${prep_file}")"

  assert_non_empty "gate_index" "${gate_index}"
  assert_non_empty "gate_type" "${gate_type}"
  assert_non_empty "wire_a" "${wire_a}"
  assert_non_empty "wire_b" "${wire_b}"
  assert_non_empty "wire_c" "${wire_c}"
  assert_non_empty "claimed_leaf" "${claimed_leaf}"
  assert_non_empty "ih_proof" "${ih_proof}"
  assert_non_empty "layout_proof" "${layout_proof}"

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
  echo "final_stage=${stage} (7 means Closed)"
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
  echo "bob_m_choice=${m_choice}"
  common_bootstrap "${m_choice}"

  phase "Phase 2: Alice submits honest commitments"
  run_alice submit-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --export-dir "${out_dir}"
  wait_phase

  phase "Phase 3: Bob chooses m"
  run_bob choose --m "${m_choice}"
  wait_phase

  phase "Phase 4: Alice reveals openings"
  run_alice reveal-openings \
    --m "${m_choice}" \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}"
  wait_phase

  phase "Phase 5: Bob submits false challenge"
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
  local ih_proof
  local layout_proof

  gate_index="$(extract_kv selected_gate_index "${prep_file}")"
  gate_type="$(extract_kv gate_type "${prep_file}")"
  wire_a="$(extract_kv wire_a "${prep_file}")"
  wire_b="$(extract_kv wire_b "${prep_file}")"
  wire_c="$(extract_kv wire_c "${prep_file}")"
  claimed_leaf="$(extract_kv claimed_leaf "${prep_file}")"
  ih_proof="$(extract_kv ih_proof "${prep_file}")"
  layout_proof="$(extract_kv layout_proof "${prep_file}")"

  assert_non_empty "gate_index" "${gate_index}"
  assert_non_empty "gate_type" "${gate_type}"
  assert_non_empty "wire_a" "${wire_a}"
  assert_non_empty "wire_b" "${wire_b}"
  assert_non_empty "wire_c" "${wire_c}"
  assert_non_empty "claimed_leaf" "${claimed_leaf}"
  assert_non_empty "ih_proof" "${ih_proof}"
  assert_non_empty "layout_proof" "${layout_proof}"

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
  echo "final_stage=${stage} (7 means Closed)"
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
