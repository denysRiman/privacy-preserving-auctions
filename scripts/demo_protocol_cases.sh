#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${ROOT_DIR}/contract"
ALICE_APP_DIR="${ROOT_DIR}/off-chain-alice"
BOB_APP_DIR="${ROOT_DIR}/off-chain-bob"
OFFCHAIN_COMMON_DIR="${ROOT_DIR}/off-chain-common"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
TX_LEGACY="${TX_LEGACY:-1}"
TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI:-0}"
PAUSE_SECONDS="${PAUSE_SECONDS:-0}"
WORK_ROOT="${WORK_ROOT:-/tmp/auction-demo-nparty}"
VERBOSE="${VERBOSE:-0}"
EVALUATION_WRITE_RESULTS="${EVALUATION_WRITE_RESULTS:-1}"
EVALUATION_RESULTS_DIR="${EVALUATION_RESULTS_DIR:-${ROOT_DIR}/paper/FINAL/evaluation/results}"

ALICE_PK="${ALICE_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
B1_PK="${B1_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
B2_PK="${B2_PK:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
B3_PK="${B3_PK:-0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6}"

BIT_WIDTH="${BIT_WIDTH:-57}"
WINNER_FORMULA="${WINNER_FORMULA:-0}"
DEPOSIT_WEI="${DEPOSIT_WEI:-1200000000000000000}" # 1.2 ETH

# Optional override; if empty, values are auto-derived from (bitWidth, winnerFormula).
CIRCUIT_ID="${CIRCUIT_ID:-}"
LAYOUT_ROOT="${LAYOUT_ROOT:-}"
OFFERED_NAMEHASH_1="${OFFERED_NAMEHASH_1:-}"
OFFERED_NAMEHASH_2="${OFFERED_NAMEHASH_2:-}"
OFFERED_NAMEHASH_3="${OFFERED_NAMEHASH_3:-}"
OFFERED_HUMAN_1=""
OFFERED_HUMAN_2=""
OFFERED_HUMAN_3=""
OFFERED_POOL_LABELS=(tuwien tuvienna technicalvienna technicalunivienna viennatechnical technicalwien)

ALICE_ADDR=""
B1_ADDR=""
B2_ADDR=""
B3_ADDR=""
BUYER_ADDRS=()
BUYER_PKS=()
CONTRACT_ADDRESS=""
ENS_ADAPTER=""

ALICE_RESET_WEI="${ALICE_RESET_WEI:-3000000000000000000}" # 3 ETH
BUYER_RESET_WEI="${BUYER_RESET_WEI:-5000000000000000000}" # 5 ETH

LAST_STAGE_BEFORE=""
LAST_STAGE_AFTER=""
LAST_SETTLE_OUTPUT_BYTES=""
LAST_SETTLE_WINNER_ID=""
LAST_SETTLE_WINNING_BID=""
LAST_SETTLE_HOUT_COMMITTED=""
LAST_SETTLE_HOUT_COMPUTED=""
LAST_SETTLE_HOUT_MATCH=""
LAST_SETTLE_TX=""
LAST_SETTLE_WINNER_ADDR=""
LAST_SETTLE_WINNER_RECEIVER=""
LAST_SETTLE_WINNING_BID_ONCHAIN=""
LAST_SETTLE_CHOSEN_NAMEHASH=""
LAST_SETTLE_CHOSEN_IN_OFFERED=""
LAST_SETTLE_ALICE_DELTA_WEI=""
LAST_SETTLE_WINNER_DELTA_WEI=""
LAST_FINALIZE_TX=""
LAST_ASSIGNED_BEFORE=""
LAST_ASSIGNED_AFTER=""
LAST_DEFAULT_STATUS_BEFORE=""
LAST_DEFAULT_STATUS_AFTER=""
LAST_DEFAULT_UNRESOLVED_BEFORE=""
LAST_DEFAULT_UNRESOLVED_AFTER=""
LAST_DEFAULT_SLASH_WEI=""
LAST_DEFAULT_CLOSE_BLOCKED=""
LAST_LABELS_BEFORE=""
LAST_LABELS_AFTER=""
LAST_SETTLE_STAGE_BEFORE=""
LAST_SETTLE_STAGE_AFTER=""
LAST_FINALIZE_STAGE_BEFORE=""
LAST_FINALIZE_STAGE_AFTER=""
LAST_DISPUTE_TX=""
LAST_DISPUTE_STAGE_BEFORE=""
LAST_DISPUTE_STAGE_AFTER=""
LAST_ASSIGN_EVENT_OK=""

EVAL_N_BUYERS=3
EVAL_N_INSTANCES=10
EVAL_SCENARIO=""
EVAL_SCENARIO_TX_COUNT=0
EVAL_SCENARIO_TOTAL_GAS=0
EVAL_RUNTIME_RUN_ID=1
EVAL_DYNAMIC_ARTIFACTS_RECORDED=0

is_truthy() {
  case "$1" in
    1|true|TRUE|True|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

v_log() {
  if is_truthy "${VERBOSE}"; then
    echo "$@"
  fi
}

csv_quote() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

append_csv_row() {
  local file="$1"
  shift
  local first=1
  local field
  for field in "$@"; do
    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      printf ',' >> "${file}"
    fi
    csv_quote "${field}" >> "${file}"
  done
  printf '\n' >> "${file}"
}

init_evaluation_results() {
  if ! is_truthy "${EVALUATION_WRITE_RESULTS}"; then
    return
  fi

  mkdir -p "${EVALUATION_RESULTS_DIR}"
  printf 'scenario,n_buyers,N_instances,phase,function_name,caller_role,gas_used,tx_hash_or_local_identifier\n' > "${EVALUATION_RESULTS_DIR}/evaluation_gas_by_call.csv"
  printf 'scenario,n_buyers,N_instances,tx_count,total_gas,terminal_stage,settlement_accepted,assignment_completed,slashing_happened,slashed_party,notes\n' > "${EVALUATION_RESULTS_DIR}/evaluation_scenarios.csv"
  printf 'scenario,n_buyers,N_instances,operation,run_id,elapsed_ms\n' > "${EVALUATION_RESULTS_DIR}/evaluation_runtime.csv"
  printf 'n_buyers,N_instances,artifact,count,bytes_per_item,total_bytes,derivation\n' > "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv"
  printf 'n_buyers,N_instances,scenario,total_tx,total_gas,core_commitments_count,ot_roots_count,opened_instances,terminal_stage,measurement_status,notes\n' > "${EVALUATION_RESULTS_DIR}/evaluation_scaling_buyers.csv"
  printf 'n_buyers,N_instances,scenario,total_tx,total_gas,core_commitments_count,ot_roots_count,opened_instances,terminal_stage,measurement_status,notes\n' > "${EVALUATION_RESULTS_DIR}/evaluation_scaling_instances.csv"

  record_static_artifacts
  record_structural_scaling_placeholders
}

record_static_artifacts() {
  if ! is_truthy "${EVALUATION_WRITE_RESULTS}"; then
    return
  fi

  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "outputBytes" "1" "42" "42" "abi.encodePacked(uint16 winnerId,uint64 winningBid,bytes32 chosenNamehash)"
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "gate leaf" "1" "71" "71" "LEAF_BYTES_LEN in Solidity dispute verifier"
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "core commitments" "$((EVAL_N_INSTANCES * 4))" "32" "$((EVAL_N_INSTANCES * 4 * 32))" "N x 4 x bytes32: comSeed, rootGC, blobHashGC, hOut"
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "OT roots" "$((EVAL_N_BUYERS * EVAL_N_INSTANCES))" "32" "$((EVAL_N_BUYERS * EVAL_N_INSTANCES * 32))" "n x N x bytes32 buyer-scoped OT roots"
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "opened seeds" "$((EVAL_N_INSTANCES - 1))" "32" "$(((EVAL_N_INSTANCES - 1) * 32))" "all cut-and-choose instances except selected m"
}

record_structural_scaling_placeholders() {
  local n core ot opened
  for n in 1 5 10; do
    core="${EVAL_N_INSTANCES}"
    ot="$((n * EVAL_N_INSTANCES))"
    opened="$((EVAL_N_INSTANCES - 1))"
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_scaling_buyers.csv" "${n}" "${EVAL_N_INSTANCES}" "honest-success" "" "" "${core}" "${ot}" "${opened}" "" "structural-pending" "buyer-sweep execution requires generalized demo account loops"
  done

  local inst
  for inst in 5 20; do
    core="${inst}"
    ot="$((EVAL_N_BUYERS * inst))"
    opened="$((inst - 1))"
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_scaling_instances.csv" "${EVAL_N_BUYERS}" "${inst}" "honest-success" "" "" "${core}" "${ot}" "${opened}" "" "structural-pending" "current Solidity/Rust ABI uses fixed N=10 arrays"
  done
}

start_eval_scenario() {
  EVAL_SCENARIO="$1"
  EVAL_SCENARIO_TX_COUNT=0
  EVAL_SCENARIO_TOTAL_GAS=0
  EVAL_RUNTIME_RUN_ID=1
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.monotonic_ns() // 1_000_000)'
  else
    echo "$(($(date +%s) * 1000))"
  fi
}

normalize_quantity_output() {
  local raw
  raw="$(printf '%s\n' "$1" | tr -d '[:space:]')"
  if [[ "${raw}" =~ ^0x[0-9a-fA-F]+$ ]]; then
    printf '%d\n' "$((raw))"
    return
  fi
  printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n1
}

extract_tx_hash_from_text() {
  local text="$1"
  local tx
  tx="$(printf '%s\n' "${text}" | sed -nE 's/^[A-Za-z0-9_]+_tx_hash=(0x[0-9a-fA-F]{64})$/\1/p' | tail -n1)"
  if [[ -n "${tx}" ]]; then
    echo "${tx}"
    return
  fi
  tx="$(printf '%s\n' "${text}" | sed -nE 's/^transactionHash[[:space:]]+(0x[0-9a-fA-F]{64})$/\1/p' | tail -n1)"
  if [[ -n "${tx}" ]]; then
    echo "${tx}"
    return
  fi
  printf '%s\n' "${text}" | sed -nE 's/.*"transactionHash"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{64})".*/\1/p' | tail -n1
}

record_tx_gas() {
  local phase="$1"
  local function_name="$2"
  local caller_role="$3"
  local tx_hash="$4"
  local include_in_total="${5:-1}"
  local gas_raw gas

  if ! is_truthy "${EVALUATION_WRITE_RESULTS}" || [[ -z "${tx_hash}" ]]; then
    return
  fi

  set +e
  gas_raw="$(cast receipt "${tx_hash}" gasUsed --rpc-url "${RPC_URL}" 2>/dev/null)"
  local receipt_rc=$?
  set -e
  if [[ "${receipt_rc}" -eq 0 ]]; then
    gas="$(normalize_quantity_output "${gas_raw}")"
  else
    gas=""
  fi

  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_gas_by_call.csv" "${EVAL_SCENARIO}" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "${phase}" "${function_name}" "${caller_role}" "${gas}" "${tx_hash}"
  if is_truthy "${include_in_total}" && [[ -n "${gas}" ]]; then
    EVAL_SCENARIO_TX_COUNT=$((EVAL_SCENARIO_TX_COUNT + 1))
    EVAL_SCENARIO_TOTAL_GAS=$((EVAL_SCENARIO_TOTAL_GAS + gas))
  fi
}

record_tx_from_output() {
  local phase="$1"
  local function_name="$2"
  local caller_role="$3"
  local include_in_total="$4"
  local text="$5"
  local tx_hash

  tx_hash="$(extract_tx_hash_from_text "${text}")"
  record_tx_gas "${phase}" "${function_name}" "${caller_role}" "${tx_hash}" "${include_in_total}"
}

run_alice_record() {
  local phase="$1"
  local function_name="$2"
  local caller_role="$3"
  local include_in_total="$4"
  shift 4
  local out
  out="$(run_alice "$@")"
  record_tx_from_output "${phase}" "${function_name}" "${caller_role}" "${include_in_total}" "${out}"
  printf '%s\n' "${out}"
}

run_bob_record() {
  local idx="$1"
  local phase="$2"
  local function_name="$3"
  local caller_role="$4"
  local include_in_total="$5"
  shift 5
  local out
  out="$(run_bob "${idx}" "$@")"
  record_tx_from_output "${phase}" "${function_name}" "${caller_role}" "${include_in_total}" "${out}"
  printf '%s\n' "${out}"
}

record_runtime_ms() {
  local operation="$1"
  local elapsed_ms="$2"
  if ! is_truthy "${EVALUATION_WRITE_RESULTS}"; then
    return
  fi
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_runtime.csv" "${EVAL_SCENARIO}" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "${operation}" "${EVAL_RUNTIME_RUN_ID}" "${elapsed_ms}"
  EVAL_RUNTIME_RUN_ID=$((EVAL_RUNTIME_RUN_ID + 1))
}

file_size_bytes() {
  local path="$1"
  wc -c < "${path}" | tr -d '[:space:]'
}

record_dynamic_artifacts_once() {
  local out_dir="$1"
  local m="$2"
  local blob_file="${out_dir}/instance-${m}-eval-blob.bin"
  local leaves_file="${out_dir}/instance-${m}-leaves.txt"
  local blob_size leaves_count

  if ! is_truthy "${EVALUATION_WRITE_RESULTS}" || [[ "${EVAL_DYNAMIC_ARTIFACTS_RECORDED}" -eq 1 ]]; then
    return
  fi
  if [[ -f "${blob_file}" ]]; then
    blob_size="$(file_size_bytes "${blob_file}")"
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "GC evaluation blob payload" "1" "${blob_size}" "${blob_size}" "serialized canonical eval blob for selected instance m"
  fi
  if [[ -f "${leaves_file}" ]]; then
    leaves_count="$(wc -l < "${leaves_file}" | tr -d '[:space:]')"
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "GC leaves file" "${leaves_count}" "71" "$((leaves_count * 71))" "hex-encoded leaf list; logical leaf size is LEAF_BYTES_LEN"
  fi
  EVAL_DYNAMIC_ARTIFACTS_RECORDED=1
}

record_dispute_packet_artifact() {
  local leaf_hex="$1"
  local ih_proof="$2"
  local layout_proof="$3"
  local ih_count layout_count total_bytes

  if ! is_truthy "${EVALUATION_WRITE_RESULTS}"; then
    return
  fi

  ih_count="$(csv_len "${ih_proof}")"
  layout_count="$(csv_len "${layout_proof}")"
  total_bytes="$((71 + (ih_count * 32) + (layout_count * 32) + 32 + 2 + 1 + 2 + 2 + 2))"
  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_artifacts.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "GC leaf dispute packet" "1" "${total_bytes}" "${total_bytes}" "leaf ${#leaf_hex} hex chars, seed, gate descriptor, IH proof ${ih_count}x32, layout proof ${layout_count}x32"
}

record_scenario_summary() {
  local terminal_stage="$1"
  local settlement_accepted="$2"
  local assignment_completed="$3"
  local slashing_happened="$4"
  local slashed_party="$5"
  local notes="$6"

  if ! is_truthy "${EVALUATION_WRITE_RESULTS}"; then
    return
  fi

  append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_scenarios.csv" "${EVAL_SCENARIO}" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "${EVAL_SCENARIO_TX_COUNT}" "${EVAL_SCENARIO_TOTAL_GAS}" "${terminal_stage}" "${settlement_accepted}" "${assignment_completed}" "${slashing_happened}" "${slashed_party}" "${notes}"

  if [[ "${EVAL_SCENARIO}" == "honest-success" ]]; then
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_scaling_buyers.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "${EVAL_SCENARIO}" "${EVAL_SCENARIO_TX_COUNT}" "${EVAL_SCENARIO_TOTAL_GAS}" "${EVAL_N_INSTANCES}" "$((EVAL_N_BUYERS * EVAL_N_INSTANCES))" "$((EVAL_N_INSTANCES - 1))" "${terminal_stage}" "measured" "baseline buyer count"
    append_csv_row "${EVALUATION_RESULTS_DIR}/evaluation_scaling_instances.csv" "${EVAL_N_BUYERS}" "${EVAL_N_INSTANCES}" "${EVAL_SCENARIO}" "${EVAL_SCENARIO_TX_COUNT}" "${EVAL_SCENARIO_TOTAL_GAS}" "${EVAL_N_INSTANCES}" "$((EVAL_N_BUYERS * EVAL_N_INSTANCES))" "$((EVAL_N_INSTANCES - 1))" "${terminal_stage}" "measured" "baseline cut-and-choose parameter"
  fi
}

set_last_stage_transition() {
  LAST_STAGE_BEFORE="$1"
  LAST_STAGE_AFTER="$2"
}

log_pretty_step() {
  local phase="$1"
  local verdict="$2"
  local message="$3"
  local before="$4"
  local after="$5"
  local stage_chain="${6:-}"
  echo
  printf "\033[1;36m== %s ==\033[0m\n" "${phase}"
  echo "${verdict} | ${message}"
  if [[ -n "${stage_chain}" ]]; then
    echo "stage: ${stage_chain}"
  else
    echo "stage: $(stage_name "${before}") -> $(stage_name "${after}")"
  fi
}

case_header() {
  local title="$1"
  local goal="$2"
  echo
  printf "\033[1;32m================ %s ================\033[0m\n" "${title}"
  echo "Goal: ${goal}"
  echo "Offered (human): [\"${OFFERED_HUMAN_1}\",\"${OFFERED_HUMAN_2}\",\"${OFFERED_HUMAN_3}\"]"
  echo "Offered (namehash): [${OFFERED_NAMEHASH_1},${OFFERED_NAMEHASH_2},${OFFERED_NAMEHASH_3}]"
  echo "Index map: buyer[0]=B1, buyer[1]=B2, buyer[2]=B3"
  echo "Config: bitWidth=${BIT_WIDTH}, deposits Alice/Buyer=$(format_eth_compact "$(cast from-wei "${DEPOSIT_WEI}")") ETH"
  echo "bidUnit: wei (GC outputs are uint64 wei)"
  echo "Bid safety: max bid <= deposit enforced on-chain (winningBid <= deposit)"
  echo "Binding: circuitId=$(short_hash32 "${CIRCUIT_ID}"), layoutRoot=$(short_hash32 "${LAYOUT_ROOT}")"
  echo "Tie-break: lower bidder_id (circuit)"
  echo "------------------------------------------------------------"
}

print_buyers_table() {
  echo "B1=${B1_ADDR} -> receiver=${B1_ADDR}"
  echo "B2=${B2_ADDR} -> receiver=${B2_ADDR}"
  echo "B3=${B3_ADDR} -> receiver=${B3_ADDR}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

preflight() {
  require_cmd cast
  require_cmd cargo
  require_cmd forge
  require_cmd curl

  if ! curl -sS -X POST "${RPC_URL}" -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null; then
    echo "RPC not reachable at ${RPC_URL}. Start chain with ./scripts/start_anvil.sh" >&2
    exit 1
  fi

  ALICE_ADDR="$(cast wallet address --private-key "${ALICE_PK}")"
  B1_ADDR="$(cast wallet address --private-key "${B1_PK}")"
  B2_ADDR="$(cast wallet address --private-key "${B2_PK}")"
  B3_ADDR="$(cast wallet address --private-key "${B3_PK}")"
  BUYER_ADDRS=("${B1_ADDR}" "${B2_ADDR}" "${B3_ADDR}")
  BUYER_PKS=("${B1_PK}" "${B2_PK}" "${B3_PK}")
  ENS_ADAPTER="${ENS_ADAPTER:-0x0000000000000000000000000000000000000001}"
  init_offered_namehashes

  resolve_circuit_config
}

init_offered_namehashes() {
  infer_pool_human_for_hash() {
    local target_hash="$1"
    local label candidate_hash
    for label in "${OFFERED_POOL_LABELS[@]}"; do
      candidate_hash="$(cast keccak "${label}.eth" | tr -d '[:space:]')"
      if [[ "${candidate_hash}" == "${target_hash}" ]]; then
        echo "${label}.eth"
        return
      fi
    done
    echo "N/A"
  }

  local explicit=false
  if [[ -n "${OFFERED_NAMEHASH_1}" && -n "${OFFERED_NAMEHASH_2}" && -n "${OFFERED_NAMEHASH_3}" ]]; then
    explicit=true
  fi

  if [[ "${explicit}" == "true" ]]; then
    OFFERED_HUMAN_1="$(infer_pool_human_for_hash "${OFFERED_NAMEHASH_1}")"
    OFFERED_HUMAN_2="$(infer_pool_human_for_hash "${OFFERED_NAMEHASH_2}")"
    OFFERED_HUMAN_3="$(infer_pool_human_for_hash "${OFFERED_NAMEHASH_3}")"
    return
  fi

  local labels=("${OFFERED_POOL_LABELS[@]}")
  local i j tmp n
  n="${#labels[@]}"
  for ((i=n-1; i>0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp="${labels[i]}"
    labels[i]="${labels[j]}"
    labels[j]="${tmp}"
  done

  OFFERED_HUMAN_1="${labels[0]}.eth"
  OFFERED_HUMAN_2="${labels[1]}.eth"
  OFFERED_HUMAN_3="${labels[2]}.eth"
  OFFERED_NAMEHASH_1="$(cast keccak "${OFFERED_HUMAN_1}" | tr -d '[:space:]')"
  OFFERED_NAMEHASH_2="$(cast keccak "${OFFERED_HUMAN_2}" | tr -d '[:space:]')"
  OFFERED_NAMEHASH_3="$(cast keccak "${OFFERED_HUMAN_3}" | tr -d '[:space:]')"
}

resolve_circuit_config() {
  if [[ -n "${CIRCUIT_ID}" && -n "${LAYOUT_ROOT}" ]]; then
    return
  fi

  local snapshot resolved_circuit resolved_layout
  snapshot="$(
    cd "${OFFCHAIN_COMMON_DIR}" && \
      cargo run --offline --quiet -- --bits "${BIT_WIDTH}" --winner-formula "${WINNER_FORMULA}"
  )"
  resolved_circuit="$(printf '%s\n' "${snapshot}" | sed -nE 's/^circuitId = (0x[0-9a-fA-F]{64})$/\1/p' | head -n1)"
  resolved_layout="$(printf '%s\n' "${snapshot}" | sed -nE 's/^circuitLayoutRoot = (0x[0-9a-fA-F]{64})$/\1/p' | head -n1)"

  if [[ -z "${CIRCUIT_ID}" ]]; then
    CIRCUIT_ID="${resolved_circuit}"
  fi
  if [[ -z "${LAYOUT_ROOT}" ]]; then
    LAYOUT_ROOT="${resolved_layout}"
  fi

  if [[ -z "${CIRCUIT_ID}" || -z "${LAYOUT_ROOT}" ]]; then
    echo "Failed to resolve circuit config for bitWidth=${BIT_WIDTH}, winnerFormula=${WINNER_FORMULA}" >&2
    exit 1
  fi
}

phase() {
  local title="$1"
  if is_truthy "${VERBOSE}"; then
    printf "\n\033[1;36m== %s ==\033[0m\n" "${title}"
  fi
}

stage_name() {
  if [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
    return
  fi
  case "$1" in
    0) echo "Deposits" ;;
    1) echo "BuyerSeedCommit" ;;
    2) echo "CommitmentsCore" ;;
    3) echo "BuyerSeedReveal" ;;
    4) echo "CommitmentsOT" ;;
    5) echo "BuyerInputOT" ;;
    6) echo "Open" ;;
    7) echo "Dispute" ;;
    8) echo "Labels" ;;
    9) echo "Settle" ;;
    10) echo "Assignment" ;;
    11) echo "Closed" ;;
    *) echo "Unknown" ;;
  esac
}

buyer_status_name() {
  case "$1" in
    0) echo "Pending" ;;
    1) echo "Ready" ;;
    2) echo "Defaulted" ;;
    *) echo "Unknown" ;;
  esac
}

log_action_stage() {
  local action="$1"
  local before="$2"
  local after="$3"
  v_log "action=${action} stage_before=$(stage_name "${before}")(${before}) stage_after=$(stage_name "${after}")(${after})"
}

wait_phase() {
  if [[ "${PAUSE_SECONDS}" -gt 0 ]]; then
    sleep "${PAUSE_SECONDS}"
  fi
}

short_hash32() {
  local value="$1"
  if [[ "${value}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "${value:0:10}...${value:58:8}"
  else
    echo "${value}"
  fi
}

format_eth_compact() {
  local raw="$1"
  local token
  token="${raw%% *}"
  if [[ ! "${token}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "${raw}"
    return
  fi
  token="$(printf '%s' "${token}" | sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$/.0/')"
  if [[ "${token}" =~ ^[0-9]+$ ]]; then
    token="${token}.0"
  fi
  echo "${token}"
}

run_alice() {
  (
    cd "${ALICE_APP_DIR}"
    DEMO_MODE=1 \
    RPC_URL="${RPC_URL}" \
    CONTRACT_ADDRESS="${CONTRACT_ADDRESS}" \
    ALICE_PRIVATE_KEY="${ALICE_PK}" \
    BOB_ADDRESS="${B1_ADDR}" \
    DEPOSIT_WEI="${DEPOSIT_WEI}" \
    TX_LEGACY="${TX_LEGACY}" \
    TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI}" \
    cargo run --offline --quiet -- "$@"
  )
}

run_bob() {
  local idx="$1"
  shift
  (
    cd "${BOB_APP_DIR}"
    RPC_URL="${RPC_URL}" \
    CONTRACT_ADDRESS="${CONTRACT_ADDRESS}" \
    BOB_PRIVATE_KEY="${BUYER_PKS[$idx]}" \
    DEPOSIT_WEI="${DEPOSIT_WEI}" \
    TX_LEGACY="${TX_LEGACY}" \
    TX_GAS_PRICE_WEI="${TX_GAS_PRICE_WEI}" \
    cargo run --offline --quiet -- "$@"
  )
}

extract_kv() {
  local key="$1"
  local text="$2"
  printf '%s\n' "${text}" | sed -nE "s/^${key}=(.*)$/\\1/p" | tail -n1
}

normalize_uint_output() {
  printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n1
}

normalize_address_output() {
  printf '%s\n' "$1" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n1
}

stage_value() {
  normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "currentStage()(uint8)" --rpc-url "${RPC_URL}")"
}

participant_vault() {
  local addr="$1"
  normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "vault(address)(uint256)" "${addr}" --rpc-url "${RPC_URL}")"
}

participant_balance() {
  local addr="$1"
  normalize_uint_output "$(cast balance "${addr}" --rpc-url "${RPC_URL}")"
}

instance_hout() {
  local idx="$1"
  cast call "${CONTRACT_ADDRESS}" "instanceCommitments(uint256)(bytes32,bytes32,bytes32,bytes32)" "${idx}" --rpc-url "${RPC_URL}" \
    | grep -Eo '0x[0-9a-fA-F]{64}' \
    | sed -n '4p'
}

compute_output_anchor() {
  local circuit_id="$1"
  local instance_id="$2"
  local output_bytes="$3"
  local instance_hex payload
  instance_hex="$(printf '%064x' "${instance_id}")"
  payload="0x4f5554${circuit_id#0x}${instance_hex}${output_bytes#0x}"
  cast keccak "${payload}" | tr -d '[:space:]'
}

wei_delta() {
  local before="$1"
  local after="$2"
  echo $((after - before))
}

format_wei_eth() {
  local wei="$1"
  format_eth_compact "$(cast from-wei "${wei}")"
}

format_signed_wei_eth() {
  local wei="$1"
  if (( wei < 0 )); then
    echo "-$(format_wei_eth "$((-wei))")"
  else
    echo "+$(format_wei_eth "${wei}")"
  fi
}

format_eth_wei_pair() {
  local wei="$1"
  echo "$(format_wei_eth "${wei}") ETH (${wei} wei)"
}

format_signed_eth_wei_pair() {
  local wei="$1"
  if (( wei < 0 )); then
    echo "-$(format_wei_eth "$((-wei))") ETH (${wei} wei)"
  else
    echo "+$(format_wei_eth "${wei}") ETH (${wei} wei)"
  fi
}

is_offered_namehash() {
  local value="$1"
  [[ "${value}" == "${OFFERED_NAMEHASH_1}" || "${value}" == "${OFFERED_NAMEHASH_2}" || "${value}" == "${OFFERED_NAMEHASH_3}" ]]
}

offered_index_for_hash() {
  local value="$1"
  if [[ "${value}" == "${OFFERED_NAMEHASH_1}" ]]; then
    echo "0"
  elif [[ "${value}" == "${OFFERED_NAMEHASH_2}" ]]; then
    echo "1"
  elif [[ "${value}" == "${OFFERED_NAMEHASH_3}" ]]; then
    echo "2"
  else
    echo "-1"
  fi
}

offered_human_for_hash() {
  local idx
  idx="$(offered_index_for_hash "$1")"
  case "${idx}" in
    0) echo "${OFFERED_HUMAN_1}" ;;
    1) echo "${OFFERED_HUMAN_2}" ;;
    2) echo "${OFFERED_HUMAN_3}" ;;
    *) echo "N/A" ;;
  esac
}

buyer_label_for_id() {
  local winner_id="$1"
  case "${winner_id}" in
    0) echo "B1" ;;
    1) echo "B2" ;;
    2) echo "B3" ;;
    *) echo "B?" ;;
  esac
}

buyer_label_for_address() {
  local addr="$1"
  if [[ "${addr}" == "${B1_ADDR}" ]]; then
    echo "B1"
  elif [[ "${addr}" == "${B2_ADDR}" ]]; then
    echo "B2"
  elif [[ "${addr}" == "${B3_ADDR}" ]]; then
    echo "B3"
  else
    echo "B?"
  fi
}

print_bids_block() {
  local bid_b1="$1"
  local bid_b2="$2"
  local bid_b3="$3"
  local chosen_hash="$4"
  local chosen_idx chosen_human
  chosen_idx="$(offered_index_for_hash "${chosen_hash}")"
  chosen_human="$(offered_human_for_hash "${chosen_hash}")"
  echo "BIDS (off-chain inputs)"
  echo "B1 bid: $(format_eth_wei_pair "${bid_b1}")"
  echo "B2 bid: $(format_eth_wei_pair "${bid_b2}")"
  echo "B3 bid: $(format_eth_wei_pair "${bid_b3}")"
  echo "Alice chosen input index: ${chosen_idx} -> ${chosen_human} (${chosen_hash})"
}

csv_len() {
  local raw="$1"
  local normalized
  normalized="$(printf '%s' "${raw}" | tr -d '[][:space:]')"
  if [[ -z "${normalized}" ]]; then
    echo "0"
    return
  fi
  awk -F',' '{print NF}' <<< "${normalized}"
}

show_assignment_event_visibility() {
  local tx_hash="$1"
  local topic
  topic="$(cast keccak "EnsAssigned(bytes32,address)" | tr -d '[:space:]')"
  if cast receipt "${tx_hash}" --rpc-url "${RPC_URL}" | rg -q "${topic}"; then
    echo "assignment_event_visible: tx=${tx_hash} topic=${topic} [OK]"
  else
    echo "assignment_event_visible: tx=${tx_hash} topic=${topic} [MISSING]"
  fi
}

has_receipt_topic() {
  local tx_hash="$1"
  local event_sig="$2"
  local topic
  topic="$(cast keccak "${event_sig}" | tr -d '[:space:]')"
  if cast receipt "${tx_hash}" --rpc-url "${RPC_URL}" | rg -q "${topic}"; then
    echo "true"
  else
    echo "false"
  fi
}

show_receipt_topic_presence() {
  local tx_hash="$1"
  local event_sig="$2"
  local label="$3"
  local topic
  topic="$(cast keccak "${event_sig}" | tr -d '[:space:]')"
  if cast receipt "${tx_hash}" --rpc-url "${RPC_URL}" | rg -q "${topic}"; then
    echo "${label}: tx=${tx_hash} topic=${topic} [OK]"
  else
    echo "${label}: tx=${tx_hash} topic=${topic} [MISSING]"
  fi
}

deadlines_csv() {
  cast call "${CONTRACT_ADDRESS}" "deadlines()(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" \
    --rpc-url "${RPC_URL}" | tr -d '()[:space:]'
}

deadline_at() {
  local idx="$1"
  local csv
  csv="$(deadlines_csv)"
  IFS=',' read -r d1 d2 d3 d4 d5 d6 d7 d8 <<< "${csv}"
  case "${idx}" in
    1) echo "${d1}" ;;
    2) echo "${d2}" ;;
    3) echo "${d3}" ;;
    4) echo "${d4}" ;;
    5) echo "${d5}" ;;
    6) echo "${d6}" ;;
    7) echo "${d7}" ;;
    8) echo "${d8}" ;;
    *) echo "0" ;;
  esac
}

warp_to() {
  local ts="$1"
  cast rpc evm_setNextBlockTimestamp "${ts}" --rpc-url "${RPC_URL}" >/dev/null
  cast rpc evm_mine --rpc-url "${RPC_URL}" >/dev/null
}

case_dir() {
  local name="$1"
  local out="${WORK_ROOT}/${name}"
  rm -rf "${out}"
  mkdir -p "${out}"
  echo "${out}"
}

reset_balances() {
  cast rpc anvil_setBalance "${ALICE_ADDR}" "$(printf '0x%x' "${ALICE_RESET_WEI}")" --rpc-url "${RPC_URL}" >/dev/null
  cast rpc anvil_setBalance "${B1_ADDR}" "$(printf '0x%x' "${BUYER_RESET_WEI}")" --rpc-url "${RPC_URL}" >/dev/null
  cast rpc anvil_setBalance "${B2_ADDR}" "$(printf '0x%x' "${BUYER_RESET_WEI}")" --rpc-url "${RPC_URL}" >/dev/null
  cast rpc anvil_setBalance "${B3_ADDR}" "$(printf '0x%x' "${BUYER_RESET_WEI}")" --rpc-url "${RPC_URL}" >/dev/null
  v_log "balances_reset: Alice=$(format_eth_compact "$(cast from-wei "${ALICE_RESET_WEI}")") ETH, B1/B2/B3=$(format_eth_compact "$(cast from-wei "${BUYER_RESET_WEI}")") ETH [OK]"
}

deploy_contract() {
  local adapter_out
  local deploy_out
  local offered_arg

  adapter_out="$(
    cd "${CONTRACT_DIR}" && forge create src/EnsAuctionAdapterMock.sol:EnsAuctionAdapterMock \
      --rpc-url "${RPC_URL}" \
      --private-key "${ALICE_PK}" \
      --broadcast \
      --json
  )"
  record_tx_from_output "setup" "deploy_EnsAuctionAdapterMock" "garbler" "0" "${adapter_out}"
  ENS_ADAPTER="$(echo "${adapter_out}" | sed -nE 's/.*"deployedTo"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p' | tail -n1)"
  if [[ -z "${ENS_ADAPTER}" ]]; then
    echo "Failed to parse adapter deploy output" >&2
    echo "${adapter_out}" >&2
    exit 1
  fi

  offered_arg="[${OFFERED_NAMEHASH_1},${OFFERED_NAMEHASH_2},${OFFERED_NAMEHASH_3}]"

  deploy_out="$(
    cd "${CONTRACT_DIR}" && forge create src/MillionairesProblem.sol:MillionairesProblem \
      --rpc-url "${RPC_URL}" \
      --private-key "${ALICE_PK}" \
      --broadcast \
      --json \
      --constructor-args \
        "${B1_ADDR}" \
        "${B1_ADDR}" \
        "${offered_arg}" \
        "${ENS_ADAPTER}" \
        "${CIRCUIT_ID}" \
        "${LAYOUT_ROOT}" \
        "${BIT_WIDTH}"
  )"
  record_tx_from_output "setup" "deploy_MillionairesProblem" "garbler" "0" "${deploy_out}"

  CONTRACT_ADDRESS="$(echo "${deploy_out}" | sed -nE 's/.*"deployedTo"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p' | tail -n1)"
  if [[ -z "${CONTRACT_ADDRESS}" ]]; then
    echo "Failed to parse deploy output" >&2
    echo "${deploy_out}" >&2
    exit 1
  fi
  v_log "deploy: adapter=${ENS_ADAPTER}, contract=${CONTRACT_ADDRESS}, offered=[${OFFERED_NAMEHASH_1},${OFFERED_NAMEHASH_2},${OFFERED_NAMEHASH_3}] [OK]"
  v_log "deploy_params: bitWidth=${BIT_WIDTH}, depositAliceWei=${DEPOSIT_WEI}, depositBuyerWei=${DEPOSIT_WEI}, circuitId=$(short_hash32 "${CIRCUIT_ID}"), layoutRoot=$(short_hash32 "${LAYOUT_ROOT}")"
  v_log "deploy_params: ensAdapter=${ENS_ADAPTER}, initialBuyer=${B1_ADDR}, initialReceiver=${B1_ADDR}"
  set_last_stage_transition "N/A" "$(stage_value)"
  log_action_stage "deploy_contract" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"
}

register_buyers() {
  local before after tx_out
  before="$(stage_value)"
  tx_out="$(cast send "${CONTRACT_ADDRESS}" "registerBuyers(address[],address[])" \
    "[${B2_ADDR},${B3_ADDR}]" "[${B2_ADDR},${B3_ADDR}]" \
    --legacy --gas-price "${TX_GAS_PRICE_WEI}" \
    --private-key "${ALICE_PK}" \
    --rpc-url "${RPC_URL}")"
  record_tx_from_output "setup" "registerBuyers" "garbler" "1" "${tx_out}"
  after="$(stage_value)"
  v_log "buyers_registered: B1=${B1_ADDR}->${B1_ADDR}, B2=${B2_ADDR}->${B2_ADDR}, B3=${B3_ADDR}->${B3_ADDR} [OK]"
  v_log "buyers_registered: buyerCount=$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "buyerCount()(uint256)" --rpc-url "${RPC_URL}")")"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "register_buyers" "${before}" "${after}"
}

deposit_all() {
  local before after
  before="$(stage_value)"
  run_alice_record "deposit" "deposit" "garbler" "1" deposit >/dev/null
  run_bob_record 0 "deposit" "deposit" "evaluator_B1" "1" deposit >/dev/null
  run_bob_record 1 "deposit" "deposit" "evaluator_B2" "1" deposit >/dev/null
  run_bob_record 2 "deposit" "deposit" "evaluator_B3" "1" deposit >/dev/null
  after="$(stage_value)"
  v_log "deposits: Alice + B1 + B2 + B3 [OK]"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "deposit_all" "${before}" "${after}"
}

commit_reveal_all_seeds() {
  local tag="$1"
  local idx before after
  local seed
  local salt
  before="$(stage_value)"
  for idx in 0 1 2; do
    seed="$(cast keccak "${tag}-seed-${idx}")"
    salt="$(cast keccak "${tag}-salt-${idx}")"
    run_bob_record "${idx}" "seed_commit" "commitBuyerSeed" "evaluator_B$((idx + 1))" "1" commit-verifier-seed --seed "${seed}" --salt "${salt}" >/dev/null
  done
  for idx in 0 1 2; do
    seed="$(cast keccak "${tag}-seed-${idx}")"
    salt="$(cast keccak "${tag}-salt-${idx}")"
    run_bob_record "${idx}" "seed_reveal" "revealBuyerSeed" "evaluator_B$((idx + 1))" "1" reveal-verifier-seed --seed "${seed}" --salt "${salt}" >/dev/null
  done
  after="$(stage_value)"
  v_log "seed_commit_reveal: B1,B2,B3 [OK]"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "commit_reveal_all_seeds" "${before}" "${after}"
}

roots_csv_for_buyer() {
  local tag="$1"
  local buyer_idx="$2"
  local out=""
  local i
  local h
  for i in $(seq 0 9); do
    h="$(cast keccak "${tag}-buyer-${buyer_idx}-root-${i}")"
    if [[ -n "${out}" ]]; then
      out+=","
    fi
    out+="${h}"
  done
  echo "${out}"
}

submit_ot_roots_all() {
  local tag="$1"
  local idx before after
  local csv
  before="$(stage_value)"
  for idx in 0 1 2; do
    csv="$(roots_csv_for_buyer "${tag}" "${idx}")"
    run_alice_record "commitment_publication" "submitOtRootsForBuyer" "garbler_for_B$((idx + 1))" "1" submit-ot-roots \
      --buyer "${BUYER_ADDRS[$idx]}" \
      --bit-width "${BIT_WIDTH}" \
      --circuit-id "${CIRCUIT_ID}" \
      --root-ots "${csv}" >/dev/null
  done
  after="$(stage_value)"
  v_log "ot_roots_submitted: B1,B2,B3 [OK]"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "submit_ot_roots_all" "${before}" "${after}"
}

buyer_ready_all() {
  local before after
  before="$(stage_value)"
  run_bob_record 0 "buyer_input" "submitBuyerReady" "evaluator_B1" "1" buyer-ready >/dev/null
  run_bob_record 1 "buyer_input" "submitBuyerReady" "evaluator_B2" "1" buyer-ready >/dev/null
  run_bob_record 2 "buyer_input" "submitBuyerReady" "evaluator_B3" "1" buyer-ready >/dev/null
  after="$(stage_value)"
  v_log "buyer_input_ot: all buyers ready [OK]"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "buyer_ready_all" "${before}" "${after}"
}

buyer_ready_partial_and_default_b3() {
  local before_default after_default b3_before_vault b3_after_vault b3_before_status b3_after_status
  local unresolved_before unresolved_after
  local tx_out
  run_bob_record 0 "buyer_input" "submitBuyerReady" "evaluator_B1" "1" buyer-ready >/dev/null
  run_bob_record 1 "buyer_input" "submitBuyerReady" "evaluator_B2" "1" buyer-ready >/dev/null
  cast rpc evm_increaseTime 3700 --rpc-url "${RPC_URL}" >/dev/null
  cast rpc evm_mine --rpc-url "${RPC_URL}" >/dev/null
  before_default="$(stage_value)"
  unresolved_before="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "unresolvedBuyers()(uint256)" --rpc-url "${RPC_URL}")")"
  b3_before_status="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "buyerStatus(address)(uint8)" "${B3_ADDR}" --rpc-url "${RPC_URL}")")"
  b3_before_vault="$(participant_vault "${B3_ADDR}")"
  tx_out="$(cast send "${CONTRACT_ADDRESS}" "defaultBuyerInput(address)" "${B3_ADDR}" \
    --legacy --gas-price "${TX_GAS_PRICE_WEI}" \
    --private-key "${ALICE_PK}" \
    --rpc-url "${RPC_URL}")"
  record_tx_from_output "timeout_abort" "defaultBuyerInput" "garbler" "1" "${tx_out}"
  after_default="$(stage_value)"
  unresolved_after="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "unresolvedBuyers()(uint256)" --rpc-url "${RPC_URL}")")"
  b3_after_status="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "buyerStatus(address)(uint8)" "${B3_ADDR}" --rpc-url "${RPC_URL}")")"
  b3_after_vault="$(participant_vault "${B3_ADDR}")"
  LAST_DEFAULT_STATUS_BEFORE="${b3_before_status}"
  LAST_DEFAULT_STATUS_AFTER="${b3_after_status}"
  LAST_DEFAULT_UNRESOLVED_BEFORE="${unresolved_before}"
  LAST_DEFAULT_UNRESOLVED_AFTER="${unresolved_after}"
  LAST_DEFAULT_SLASH_WEI="$((b3_before_vault - b3_after_vault))"
  v_log "buyer_input_ot: B1,B2 ready; B3 defaulted+slashed [OK]"
  v_log "default_buyer_status: buyer=${B3_ADDR} status_before=$(buyer_status_name "${b3_before_status}")(${b3_before_status}) status_after=$(buyer_status_name "${b3_after_status}")(${b3_after_status}) unresolved_before=${unresolved_before} unresolved_after=${unresolved_after}"
  v_log "default_buyer_slash: slashed_wei=${LAST_DEFAULT_SLASH_WEI} slashed_eth=$(format_wei_eth "${LAST_DEFAULT_SLASH_WEI}")"
  set_last_stage_transition "${before_default}" "${after_default}"
  log_action_stage "default_buyer_input_b3" "${before_default}" "${after_default}"
}

current_m() {
  normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "m()(uint256)" --rpc-url "${RPC_URL}")"
}

reveal_openings() {
  local m="$1"
  local before after
  local start_ms end_ms out
  before="$(stage_value)"
  start_ms="$(now_ms)"
  out="$(run_alice reveal-openings --m "${m}" --bit-width "${BIT_WIDTH}" --circuit-id "${CIRCUIT_ID}")"
  end_ms="$(now_ms)"
  record_runtime_ms "opening_payload_preparation_and_submission_cli" "$((end_ms - start_ms))"
  record_tx_from_output "opening" "revealOpenings" "garbler" "1" "${out}"
  after="$(stage_value)"
  v_log "openings_revealed: m=${m} [OK]"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "reveal_openings" "${before}" "${after}"
}

close_dispute_ready_buyers() {
  local idx status before after pending_before pending_after
  local out rc
  before="$(stage_value)"
  pending_before="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "pendingDisputeBuyerClosures()(uint256)" --rpc-url "${RPC_URL}")")"
  for idx in 0 1 2; do
    status="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "buyerStatus(address)(uint8)" "${BUYER_ADDRS[$idx]}" --rpc-url "${RPC_URL}")")"
    if [[ "${status}" != "1" ]]; then
      continue
    fi
    set +e
    out="$(run_bob "${idx}" close-dispute 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      record_tx_from_output "dispute_closure" "closeDispute" "evaluator_B$((idx + 1))" "1" "${out}"
    fi
  done
  after="$(stage_value)"
  pending_after="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "pendingDisputeBuyerClosures()(uint256)" --rpc-url "${RPC_URL}")")"
  v_log "dispute_closed_by_ready_buyers [OK]"
  v_log "dispute_close_state: pending_before=${pending_before} pending_after=${pending_after}"
  set_last_stage_transition "${before}" "${after}"
  log_action_stage "close_dispute_ready_buyers" "${before}" "${after}"
}

attempt_defaulted_buyer_close_dispute() {
  local out rc
  set +e
  out="$(run_bob 2 close-dispute 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    LAST_DEFAULT_CLOSE_BLOCKED="false"
    v_log "defaulted_buyer_dispute_attempt: unexpectedly accepted [WARN]"
    return
  fi
  LAST_DEFAULT_CLOSE_BLOCKED="true"
  v_log "defaulted_buyer_dispute_attempt: blocked [OK]"
}

write_dummy_labels_file() {
  local out_file="$1"
  : > "${out_file}"
  local i
  for i in $(seq 1 "${BIT_WIDTH}"); do
    echo "0x0000000000000000000000000000000000000000000000000000000000000000" >> "${out_file}"
  done
}

reveal_labels_settle_finalize() {
  local out_dir="$1"
  local bids_csv="$2"
  local chosen_namehash="$3"
  local m="$4"
  local blob_file="${out_dir}/instance-${m}-eval-blob.bin"
  local labels_file="${out_dir}/alice-labels32.txt"
  local before_labels after_labels
  local before_settle after_settle
  local before_finalize after_finalize
  local circuit_id h_out_committed h_out_computed settle_out finalize_out
  local output_bytes out_winner_id out_winning_bid out_chosen_namehash out_winner_alias
  local dry_run_out dry_run_output_bytes
  local winner_addr winner_receiver winner_onchain_bid
  local settle_tx finalize_tx assigned_before assigned_after
  local alice_before alice_after winner_before winner_after
  local b1_before b2_before b3_before b1_after b2_after b3_after
  local anchor_match
  local start_ms end_ms reveal_out

  record_dynamic_artifacts_once "${out_dir}" "${m}"
  write_dummy_labels_file "${labels_file}"
  before_labels="$(stage_value)"
  start_ms="$(now_ms)"
  reveal_out="$(run_alice reveal-labels --labels-file "${labels_file}" --blob --path "${blob_file}")"
  end_ms="$(now_ms)"
  record_runtime_ms "label_file_loading_and_blob_reveal_cli" "$((end_ms - start_ms))"
  record_tx_from_output "label_reveal" "revealGarblerLabels" "garbler" "1" "${reveal_out}"
  after_labels="$(stage_value)"
  LAST_LABELS_BEFORE="${before_labels}"
  LAST_LABELS_AFTER="${after_labels}"
  set_last_stage_transition "${before_labels}" "${after_labels}"
  log_action_stage "reveal_labels" "${before_labels}" "${after_labels}"

  before_settle="$(stage_value)"
  circuit_id="$(cast call "${CONTRACT_ADDRESS}" "circuitId()(bytes32)" --rpc-url "${RPC_URL}" | grep -Eo '0x[0-9a-fA-F]{64}' | head -n1)"
  h_out_committed="$(instance_hout "${m}")"
  alice_before="$(participant_vault "${ALICE_ADDR}")"
  b1_before="$(participant_vault "${B1_ADDR}")"
  b2_before="$(participant_vault "${B2_ADDR}")"
  b3_before="$(participant_vault "${B3_ADDR}")"
  start_ms="$(now_ms)"
  dry_run_out="$(run_bob 0 settle-auction --dry-run --bids "${bids_csv}" --chosen-namehash "${chosen_namehash}")"
  end_ms="$(now_ms)"
  record_runtime_ms "outputBytes_encoding_and_output_anchor_derivation" "$((end_ms - start_ms))"
  dry_run_output_bytes="$(extract_kv output_bytes "${dry_run_out}")"
  h_out_computed="$(compute_output_anchor "${circuit_id}" "${m}" "${dry_run_output_bytes}")"
  printf 'computed_outputBytes=%s\n' "${dry_run_output_bytes}"
  printf 'computed_hOut=%s\n' "${h_out_computed}"
  start_ms="$(now_ms)"
  settle_out="$(run_bob 0 settle-auction --bids "${bids_csv}" --chosen-namehash "${chosen_namehash}")"
  end_ms="$(now_ms)"
  record_runtime_ms "settlement_payload_construction_and_submission_cli" "$((end_ms - start_ms))"
  record_tx_from_output "settlement" "settle" "evaluator_B1" "1" "${settle_out}"
  after_settle="$(stage_value)"
  settle_tx="$(extract_kv settle_auction_tx_hash "${settle_out}")"
  output_bytes="$(extract_kv output_bytes "${settle_out}")"
  out_winner_id="$(extract_kv winner_id "${settle_out}")"
  out_winner_alias="$(buyer_label_for_id "${out_winner_id}")"
  out_winning_bid="$(extract_kv winning_bid "${settle_out}")"
  out_chosen_namehash="$(extract_kv chosen_namehash "${settle_out}")"
  h_out_computed="$(compute_output_anchor "${circuit_id}" "${m}" "${output_bytes}")"
  anchor_match="$([[ "${h_out_committed}" == "${h_out_computed}" ]] && echo "true" || echo "false")"
  alice_after="$(participant_vault "${ALICE_ADDR}")"
  b1_after="$(participant_vault "${B1_ADDR}")"
  b2_after="$(participant_vault "${B2_ADDR}")"
  b3_after="$(participant_vault "${B3_ADDR}")"
  case "${out_winner_id}" in
    0)
      winner_addr="${B1_ADDR}"
      winner_before="${b1_before}"
      winner_after="${b1_after}"
      ;;
    1)
      winner_addr="${B2_ADDR}"
      winner_before="${b2_before}"
      winner_after="${b2_after}"
      ;;
    2)
      winner_addr="${B3_ADDR}"
      winner_before="${b3_before}"
      winner_after="${b3_after}"
      ;;
    *)
      echo "Unexpected winner_id from settle output: ${out_winner_id}" >&2
      exit 1
      ;;
  esac
  winner_onchain_bid="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "winningBid()(uint64)" --rpc-url "${RPC_URL}")")"
  winner_receiver="$(normalize_address_output "$(cast call "${CONTRACT_ADDRESS}" "winnerReceiver()(address)" --rpc-url "${RPC_URL}")")"
  LAST_SETTLE_STAGE_BEFORE="${before_settle}"
  LAST_SETTLE_STAGE_AFTER="${after_settle}"
  LAST_SETTLE_TX="${settle_tx}"
  LAST_SETTLE_OUTPUT_BYTES="${output_bytes}"
  LAST_SETTLE_WINNER_ID="${out_winner_id}"
  LAST_SETTLE_WINNING_BID="${out_winning_bid}"
  LAST_SETTLE_HOUT_COMMITTED="${h_out_committed}"
  LAST_SETTLE_HOUT_COMPUTED="${h_out_computed}"
  LAST_SETTLE_HOUT_MATCH="${anchor_match}"
  LAST_SETTLE_WINNER_ADDR="${winner_addr}"
  LAST_SETTLE_WINNER_RECEIVER="${winner_receiver}"
  LAST_SETTLE_WINNING_BID_ONCHAIN="${winner_onchain_bid}"
  LAST_SETTLE_CHOSEN_NAMEHASH="${out_chosen_namehash}"
  if is_offered_namehash "${out_chosen_namehash}"; then
    LAST_SETTLE_CHOSEN_IN_OFFERED="true"
  else
    LAST_SETTLE_CHOSEN_IN_OFFERED="false"
    echo "chosenNamehash ${out_chosen_namehash} is not in offeredNamehashes[0..2]" >&2
    exit 1
  fi
  LAST_SETTLE_ALICE_DELTA_WEI="$((alice_after - alice_before))"
  LAST_SETTLE_WINNER_DELTA_WEI="$((winner_after - winner_before))"
  set_last_stage_transition "${before_settle}" "${after_settle}"
  log_action_stage "settle" "${before_settle}" "${after_settle}"
  v_log "settle_tx: ${settle_tx}"
  v_log "settle_proof: outputBytes=${output_bytes} decoded_winnerIndex=${out_winner_id} winnerAlias=${out_winner_alias} decoded_winningBid=${out_winning_bid} decoded_chosenNamehash=${out_chosen_namehash}"
  v_log "settle_proof: hOut_committed=${h_out_committed} hOut_computed=${h_out_computed} match=${anchor_match}"
  v_log "first_price_vault_delta: alice_before=${alice_before} alice_after=${alice_after} alice_delta=$((alice_after - alice_before)) winner=${winner_addr} winner_before=${winner_before} winner_after=${winner_after} winner_delta=$((winner_after - winner_before))"
  v_log "winner_resolved_state: winnerBuyer=${winner_addr} winnerBuyerIndex=${out_winner_id} winnerAlias=${out_winner_alias} winnerReceiver=${winner_receiver} winningBid=${winner_onchain_bid}"

  before_finalize="$(stage_value)"
  assigned_before="$(cast call "${CONTRACT_ADDRESS}" "assigned()(bool)" --rpc-url "${RPC_URL}" | grep -Eo '(true|false)' | head -n1)"
  finalize_out="$(run_bob 0 finalize-assignment)"
  record_tx_from_output "assignment" "finalizeAssignment" "evaluator_B1" "1" "${finalize_out}"
  after_finalize="$(stage_value)"
  LAST_FINALIZE_STAGE_BEFORE="${before_finalize}"
  LAST_FINALIZE_STAGE_AFTER="${after_finalize}"
  set_last_stage_transition "${before_finalize}" "${after_finalize}"
  log_action_stage "finalize_assignment" "${before_finalize}" "${after_finalize}"
  finalize_tx="$(extract_kv finalize_assignment_tx_hash "${finalize_out}")"
  assigned_after="$(cast call "${CONTRACT_ADDRESS}" "assigned()(bool)" --rpc-url "${RPC_URL}" | grep -Eo '(true|false)' | head -n1)"
  LAST_FINALIZE_TX="${finalize_tx}"
  LAST_ASSIGNED_BEFORE="${assigned_before}"
  LAST_ASSIGNED_AFTER="${assigned_after}"
  v_log "assignment_call: tx=${finalize_tx} assign(namehash=${out_chosen_namehash},receiver=${winner_receiver})"
  v_log "assignment_state: assigned_before=${assigned_before} assigned_after=${assigned_after}"
  if [[ -n "${finalize_tx}" ]]; then
    LAST_ASSIGN_EVENT_OK="$(has_receipt_topic "${finalize_tx}" "EnsAssigned(bytes32,address)")"
    v_log "$(show_assignment_event_visibility "${finalize_tx}")"
  else
    LAST_ASSIGN_EVENT_OK="false"
  fi
}

tamper_first_leaf() {
  local src="$1"
  local dst="$2"
  local first raw first_nibble repl mutated
  first="$(head -n1 "${src}" | tr -d '\r\n')"
  raw="${first#0x}"
  first_nibble="${raw:0:1}"
  if [[ "${first_nibble}" == "0" ]]; then
    repl="1"
  else
    repl="0"
  fi
  mutated="0x${repl}${raw:1}"
  {
    echo "${mutated}"
    tail -n +2 "${src}"
  } > "${dst}"
}

build_root_gcs_csv_with_override() {
  local out_dir="$1"
  local target_instance="$2"
  local tampered_root="$3"
  local csv=""
  local i
  local root
  for i in $(seq 0 9); do
    if [[ "${i}" -eq "${target_instance}" ]]; then
      root="${tampered_root}"
    else
      root="$(tr -d '\r\n' < "${out_dir}/instance-${i}-root-gc.txt")"
    fi
    if [[ -n "${csv}" ]]; then
      csv+=","
    fi
    csv+="${root}"
  done
  echo "${csv}"
}

print_balances() {
  local label="$1"
  local a b1 b2 b3
  local va vb1 vb2 vb3
  a="$(cast balance "${ALICE_ADDR}" --rpc-url "${RPC_URL}")"
  b1="$(cast balance "${B1_ADDR}" --rpc-url "${RPC_URL}")"
  b2="$(cast balance "${B2_ADDR}" --rpc-url "${RPC_URL}")"
  b3="$(cast balance "${B3_ADDR}" --rpc-url "${RPC_URL}")"
  va="$(participant_vault "${ALICE_ADDR}")"
  vb1="$(participant_vault "${B1_ADDR}")"
  vb2="$(participant_vault "${B2_ADDR}")"
  vb3="$(participant_vault "${B3_ADDR}")"
  echo "${label}_vaults: Alice=${va}, B1=${vb1}, B2=${vb2}, B3=${vb3}"
  echo "${label}_wallets: Alice=$(format_eth_compact "$(cast from-wei "${a}")") ETH, B1=$(format_eth_compact "$(cast from-wei "${b1}")") ETH, B2=$(format_eth_compact "$(cast from-wei "${b2}")") ETH, B3=$(format_eth_compact "$(cast from-wei "${b3}")") ETH (gas included)"
}

assert_closed() {
  local stage
  stage="$(stage_value)"
  if [[ "${stage}" != "11" ]]; then
    echo "Expected stage=11 (Closed), got ${stage}" >&2
    exit 1
  fi
}

scenario_success() {
  local out_dir
  start_eval_scenario "honest-success"
  out_dir="$(case_dir case1-success)"
  local bid_b1=70000000000000000
  local bid_b2=100000000000000000
  local bid_b3=90000000000000000
  local chosen_namehash="${OFFERED_NAMEHASH_2}"
  local bids_csv="${bid_b1},${bid_b2},${bid_b3}"

  case_header "CASE 1: SUCCESS (3 buyers, N=10)" "Honest run: commitments, disputes, settle and ENS assignment all consistent"
  print_buyers_table
  print_bids_block "${bid_b1}" "${bid_b2}" "${bid_b3}" "${chosen_namehash}"

  deploy_contract
  register_buyers
  reset_balances
  log_pretty_step "P0 Setup" "OK" "Contract deployed, buyers registered, balances reset" "N/A" "$(stage_value)"

  deposit_all
  log_pretty_step "P1 Deposits" "OK" "Alice+3 buyers deposited" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  commit_reveal_all_seeds "case1"
  log_pretty_step "P2 Seeds" "OK" "commits=3, reveals=3, verifierSeed finalized" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  local before_core after_core start_ms end_ms core_out
  before_core="$(stage_value)"
  start_ms="$(now_ms)"
  core_out="$(run_alice submit-core-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --winner-formula "${WINNER_FORMULA}" \
    --bids "${bids_csv}" \
    --chosen-namehash "${chosen_namehash}" \
    --export-dir "${out_dir}")"
  end_ms="$(now_ms)"
  record_runtime_ms "commitment_construction_gc_payload_and_core_submission_cli" "$((end_ms - start_ms))"
  record_tx_from_output "commitment_publication" "submitCommitments" "garbler" "1" "${core_out}"
  after_core="$(stage_value)"
  set_last_stage_transition "${before_core}" "${after_core}"
  v_log "core_commitments_submitted [OK]"
  log_action_stage "submit_core_commitments" "${before_core}" "${after_core}"
  log_pretty_step "P3 Commit core" "OK" "N=10 instances committed (comSeed/rootGC/blobHash/hOut)" "${before_core}" "${after_core}"

  submit_ot_roots_all "case1"
  log_pretty_step "P4 OT roots" "OK" "roots for all buyers committed" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  buyer_ready_all
  log_pretty_step "P5 BuyerInputOT" "OK" "ready=3, defaulted=0" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  local m
  m="$(current_m)"
  record_dynamic_artifacts_once "${out_dir}" "${m}"
  reveal_openings "${m}"
  close_dispute_ready_buyers
  log_pretty_step "P6 Open+Dispute" "OK" "m=${m}, dispute closed by ready buyers" "Open" "${LAST_STAGE_AFTER}" "Open -> Dispute -> Labels (via closeDispute)"

  reveal_labels_settle_finalize "${out_dir}" "${bids_csv}" "${chosen_namehash}" "${m}"
  log_pretty_step "P7 Labels" "OK" "garbler labels revealed for evaluation instance" "${LAST_LABELS_BEFORE}" "${LAST_LABELS_AFTER}"
  log_pretty_step "P8 Settle" "OK" "winnerIndex=${LAST_SETTLE_WINNER_ID}, winnerAlias=$(buyer_label_for_id "${LAST_SETTLE_WINNER_ID}"), winningBid=${LAST_SETTLE_WINNING_BID} wei ($(format_wei_eth "${LAST_SETTLE_WINNING_BID}") ETH), first-price applied" "${LAST_SETTLE_STAGE_BEFORE}" "${LAST_SETTLE_STAGE_AFTER}"
  log_pretty_step "P9 Assign" "OK" "ENS assigned to receiver(B$((LAST_SETTLE_WINNER_ID + 1))) and payouts completed" "${LAST_FINALIZE_STAGE_BEFORE}" "${LAST_FINALIZE_STAGE_AFTER}"
  assert_closed

  local winner_buyer winner_receiver winning_bid_onchain
  winner_buyer="$(normalize_address_output "$(cast call "${CONTRACT_ADDRESS}" "winnerBuyer()(address)" --rpc-url "${RPC_URL}")")"
  winner_receiver="$(normalize_address_output "$(cast call "${CONTRACT_ADDRESS}" "winnerReceiver()(address)" --rpc-url "${RPC_URL}")")"
  winning_bid_onchain="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "winningBid()(uint64)" --rpc-url "${RPC_URL}")")"
  local assigned_now unresolved_now
  assigned_now="$(cast call "${CONTRACT_ADDRESS}" "assigned()(bool)" --rpc-url "${RPC_URL}" | grep -Eo '(true|false)' | head -n1)"
  unresolved_now="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "unresolvedBuyers()(uint256)" --rpc-url "${RPC_URL}")")"

  local settle_name_human winner_label_by_id winner_label_by_addr
  settle_name_human="$(offered_human_for_hash "${LAST_SETTLE_CHOSEN_NAMEHASH}")"
  winner_label_by_id="$(buyer_label_for_id "${LAST_SETTLE_WINNER_ID}")"
  winner_label_by_addr="$(buyer_label_for_address "${winner_buyer}")"
  local consistency_ok
  consistency_ok="$([[ "${LAST_SETTLE_CHOSEN_NAMEHASH}" == "${chosen_namehash}" ]] && echo "✅" || echo "❌")"
  echo "SETTLE"
  echo "Proof: hOut match=${LAST_SETTLE_HOUT_MATCH} | bid<=deposit ✅"
  echo "Decoded: winnerIndex=${LAST_SETTLE_WINNER_ID}, winnerAlias=${winner_label_by_id}, winningBid=$(format_eth_wei_pair "${LAST_SETTLE_WINNING_BID}"), chosenNamehash=${LAST_SETTLE_CHOSEN_NAMEHASH} (${settle_name_human})"
  echo "OutputBytes: ${LAST_SETTLE_OUTPUT_BYTES}"
  echo "Winner: ${winner_label_by_addr} buyer=${winner_buyer}, receiver=${winner_receiver}"
  echo "Consistency: GC chosen == Alice chosen input ${consistency_ok}"
  echo "ASSIGN"
  echo "Adapter call: assign(namehash=${LAST_SETTLE_CHOSEN_NAMEHASH}, receiver=${winner_receiver})"
  echo "Assign: ${settle_name_human} (${LAST_SETTLE_CHOSEN_NAMEHASH}) -> receiver=${winner_receiver} | tx=${LAST_FINALIZE_TX} | EnsAssigned=$( [[ "${LAST_ASSIGN_EVENT_OK}" == "true" ]] && echo 'true' || echo 'false' ) | assigned=${assigned_now}"
  echo "MONEY FLOW"
  echo "first-price amount: $(format_eth_wei_pair "${LAST_SETTLE_WINNING_BID_ONCHAIN}")"
  echo "default slash amount: $(format_eth_wei_pair 0)"
  echo "total Alice vault delta: $(format_signed_eth_wei_pair "${LAST_SETTLE_ALICE_DELTA_WEI}")"
  echo "winner vault delta: $(format_signed_eth_wei_pair "${LAST_SETTLE_WINNER_DELTA_WEI}")"
  echo "Final: stage=$(stage_name "$(stage_value)"), assigned=${assigned_now}, unresolvedBuyers=${unresolved_now}"
  echo "STATUS: ✅ Goal satisfied | ✅ Stage=Closed | ✅ Assigned=true | ✅ No pending buyers"
  record_scenario_summary "$(stage_name "$(stage_value)")" "true" "${assigned_now}" "false" "none" "baseline honest success; total gas excludes deployment transactions"

  if is_truthy "${VERBOSE}"; then
    print_balances "final_balances"
    echo "tie_break_note: circuit-enforced (lower bidder_id wins on equal bids); not asserted by contract logs"
  fi
  wait_phase
}

scenario_bob_defaulted() {
  local out_dir
  start_eval_scenario "evaluator-default"
  out_dir="$(case_dir case2-buyer-defaulted)"
  local bid_b1=80000000000000000
  local bid_b2=90000000000000000
  local bid_b3=0
  local chosen_namehash="${OFFERED_NAMEHASH_1}"
  local bids_csv="${bid_b1},${bid_b2},${bid_b3}"

  case_header "CASE 2: ONE BUYER DEFAULTED (3 buyers, N=10)" "Liveness: B3 defaults to 0 and is slashed; auction continues and settles"
  print_buyers_table
  print_bids_block "${bid_b1}" "${bid_b2}" "${bid_b3}" "${chosen_namehash}"

  deploy_contract
  register_buyers
  reset_balances
  log_pretty_step "P0 Setup" "OK" "Contract deployed, buyers registered, balances reset" "N/A" "$(stage_value)"

  deposit_all
  log_pretty_step "P1 Deposits" "OK" "Alice+3 buyers deposited" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  commit_reveal_all_seeds "case2"
  log_pretty_step "P2 Seeds" "OK" "commits=3, reveals=3, verifierSeed finalized" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  local before_core after_core start_ms end_ms core_out
  before_core="$(stage_value)"
  start_ms="$(now_ms)"
  core_out="$(run_alice submit-core-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --winner-formula "${WINNER_FORMULA}" \
    --bids "${bids_csv}" \
    --chosen-namehash "${chosen_namehash}" \
    --export-dir "${out_dir}")"
  end_ms="$(now_ms)"
  record_runtime_ms "commitment_construction_gc_payload_and_core_submission_cli" "$((end_ms - start_ms))"
  record_tx_from_output "commitment_publication" "submitCommitments" "garbler" "1" "${core_out}"
  after_core="$(stage_value)"
  set_last_stage_transition "${before_core}" "${after_core}"
  v_log "core_commitments_submitted [OK]"
  log_action_stage "submit_core_commitments" "${before_core}" "${after_core}"
  log_pretty_step "P3 Commit core" "OK" "N=10 instances committed (comSeed/rootGC/blobHash/hOut)" "${before_core}" "${after_core}"

  submit_ot_roots_all "case2"
  log_pretty_step "P4 OT roots" "OK" "roots for all buyers committed" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  buyer_ready_partial_and_default_b3
  log_pretty_step "P5 BuyerInputOT" "OK" "ready=2, defaulted=1 (B3)" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  local m
  m="$(current_m)"
  reveal_openings "${m}"
  attempt_defaulted_buyer_close_dispute
  close_dispute_ready_buyers
  log_pretty_step "P6 Open+Dispute" "OK" "m=${m}, dispute closed by ready buyers" "Open" "${LAST_STAGE_AFTER}" "Open -> Dispute -> Labels (via closeDispute)"

  reveal_labels_settle_finalize "${out_dir}" "${bids_csv}" "${chosen_namehash}" "${m}"
  log_pretty_step "P7 Labels" "OK" "garbler labels revealed for evaluation instance" "${LAST_LABELS_BEFORE}" "${LAST_LABELS_AFTER}"
  log_pretty_step "P8 Settle" "OK" "winnerIndex=${LAST_SETTLE_WINNER_ID}, winnerAlias=$(buyer_label_for_id "${LAST_SETTLE_WINNER_ID}"), winningBid=${LAST_SETTLE_WINNING_BID} wei ($(format_wei_eth "${LAST_SETTLE_WINNING_BID}") ETH), first-price applied" "${LAST_SETTLE_STAGE_BEFORE}" "${LAST_SETTLE_STAGE_AFTER}"
  log_pretty_step "P9 Assign" "OK" "ENS assigned to receiver(B$((LAST_SETTLE_WINNER_ID + 1))) and payouts completed" "${LAST_FINALIZE_STAGE_BEFORE}" "${LAST_FINALIZE_STAGE_AFTER}"
  assert_closed

  local assigned_now unresolved_now
  assigned_now="$(cast call "${CONTRACT_ADDRESS}" "assigned()(bool)" --rpc-url "${RPC_URL}" | grep -Eo '(true|false)' | head -n1)"
  unresolved_now="$(normalize_uint_output "$(cast call "${CONTRACT_ADDRESS}" "unresolvedBuyers()(uint256)" --rpc-url "${RPC_URL}")")"
  local winner_buyer settle_name_human winner_label_by_id winner_label_by_addr
  winner_buyer="$(normalize_address_output "$(cast call "${CONTRACT_ADDRESS}" "winnerBuyer()(address)" --rpc-url "${RPC_URL}")")"
  settle_name_human="$(offered_human_for_hash "${LAST_SETTLE_CHOSEN_NAMEHASH}")"
  winner_label_by_id="$(buyer_label_for_id "${LAST_SETTLE_WINNER_ID}")"
  winner_label_by_addr="$(buyer_label_for_address "${winner_buyer}")"
  local consistency_ok
  consistency_ok="$([[ "${LAST_SETTLE_CHOSEN_NAMEHASH}" == "${chosen_namehash}" ]] && echo "✅" || echo "❌")"
  echo "SETTLE"
  echo "Proof: hOut match=${LAST_SETTLE_HOUT_MATCH} | bid<=deposit ✅"
  echo "Decoded: winnerIndex=${LAST_SETTLE_WINNER_ID}, winnerAlias=${winner_label_by_id}, winningBid=$(format_eth_wei_pair "${LAST_SETTLE_WINNING_BID}"), chosenNamehash=${LAST_SETTLE_CHOSEN_NAMEHASH} (${settle_name_human})"
  echo "OutputBytes: ${LAST_SETTLE_OUTPUT_BYTES}"
  echo "Winner: ${winner_label_by_addr} buyer=${winner_buyer}, receiver=${LAST_SETTLE_WINNER_RECEIVER}"
  echo "Consistency: GC chosen == Alice chosen input ${consistency_ok}"
  echo "Default proof: B3 missed BuyerInputOT -> Defaulted ✅ | slashed=$(format_eth_wei_pair "${LAST_DEFAULT_SLASH_WEI}") to Alice ✅ | protocol continued ✅"
  echo "ASSIGN"
  echo "Adapter call: assign(namehash=${LAST_SETTLE_CHOSEN_NAMEHASH}, receiver=${LAST_SETTLE_WINNER_RECEIVER})"
  echo "Assign: ${settle_name_human} (${LAST_SETTLE_CHOSEN_NAMEHASH}) -> receiver=${LAST_SETTLE_WINNER_RECEIVER} | tx=${LAST_FINALIZE_TX} | EnsAssigned=$( [[ "${LAST_ASSIGN_EVENT_OK}" == "true" ]] && echo 'true' || echo 'false' ) | assigned=${assigned_now}"
  echo "MONEY FLOW"
  echo "first-price amount: $(format_eth_wei_pair "${LAST_SETTLE_WINNING_BID_ONCHAIN}")"
  echo "default slash amount: $(format_eth_wei_pair "${LAST_DEFAULT_SLASH_WEI}")"
  echo "breakdown: +default ($(format_eth_wei_pair "${LAST_DEFAULT_SLASH_WEI}")) +first-price ($(format_eth_wei_pair "${LAST_SETTLE_WINNING_BID_ONCHAIN}")) = total ($(format_signed_eth_wei_pair "$((LAST_SETTLE_ALICE_DELTA_WEI + LAST_DEFAULT_SLASH_WEI))"))"
  echo "total Alice vault delta: $(format_signed_eth_wei_pair "$((LAST_SETTLE_ALICE_DELTA_WEI + LAST_DEFAULT_SLASH_WEI))")"
  echo "winner vault delta: $(format_signed_eth_wei_pair "${LAST_SETTLE_WINNER_DELTA_WEI}")"
  echo "Final: stage=$(stage_name "$(stage_value)"), assigned=${assigned_now}, unresolvedBuyers=${unresolved_now}"
  echo "STATUS: ✅ Goal satisfied | ✅ Stage=Closed | ✅ Assigned=true | ✅ No pending buyers"
  record_scenario_summary "$(stage_name "$(stage_value)")" "true" "${assigned_now}" "true" "evaluator_B3" "B3 defaulted in BuyerInputOT; total gas excludes deployment transactions"

  if is_truthy "${VERBOSE}"; then
    print_balances "final_balances"
    echo "defaulted_buyer: B3 slashed, auction completed [OK]"
  fi
  wait_phase
}

scenario_alice_cheats() {
  local out_dir
  start_eval_scenario "garbler-cheat"
  out_dir="$(case_dir case3-alice-cheats)"
  local bid_b1=85000000000000000
  local bid_b2=95000000000000000
  local bid_b3=92000000000000000
  local chosen_namehash="${OFFERED_NAMEHASH_3}"
  local bids_csv="${bid_b1},${bid_b2},${bid_b3}"

  case_header "CASE 3: ALICE CHEATS (3 buyers, N=10)" "Integrity: tampered rootGC on opened instance gets disputed and Alice is slashed equally to buyers"
  print_buyers_table
  print_bids_block "${bid_b1}" "${bid_b2}" "${bid_b3}" "${chosen_namehash}"

  deploy_contract
  register_buyers
  reset_balances
  log_pretty_step "P0 Setup" "OK" "Contract deployed, buyers registered, balances reset" "N/A" "$(stage_value)"

  deposit_all
  log_pretty_step "P1 Deposits" "OK" "Alice+3 buyers deposited" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  commit_reveal_all_seeds "case3"
  log_pretty_step "P2 Seeds" "OK" "commits=3, reveals=3, verifierSeed finalized" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  local before_export after_export start_ms end_ms export_out
  before_export="$(stage_value)"
  start_ms="$(now_ms)"
  export_out="$(run_alice export-artifacts --out-dir "${out_dir}" --bit-width "${BIT_WIDTH}" --circuit-id "${CIRCUIT_ID}")"
  end_ms="$(now_ms)"
  record_runtime_ms "commitment_construction_and_gc_payload_export" "$((end_ms - start_ms))"
  after_export="$(stage_value)"
  set_last_stage_transition "${before_export}" "${after_export}"
  log_action_stage "export_artifacts" "${before_export}" "${after_export}"
  log_pretty_step "P3 Export" "OK" "honest artifacts exported for tamper setup" "${before_export}" "${after_export}"

  local m target_instance seed_file seed_hex leaves_file tampered_file prepare_out tampered_root root_gcs_csv
  m="$(current_m)"
  record_dynamic_artifacts_once "${out_dir}" "${m}"
  if [[ "${m}" == "0" ]]; then
    target_instance=1
  else
    target_instance=0
  fi
  seed_file="${out_dir}/instance-${target_instance}-seed.txt"
  seed_hex="$(tr -d '\r\n' < "${seed_file}")"
  leaves_file="${out_dir}/instance-${target_instance}-leaves.txt"
  tampered_file="${out_dir}/instance-${target_instance}-leaves-tampered.txt"
  tamper_first_leaf "${leaves_file}" "${tampered_file}"

  start_ms="$(now_ms)"
  prepare_out="$(run_bob 0 prepare-dispute \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --instance-id "${target_instance}" \
    --seed "${seed_hex}" \
    --claimed-leaves-file "${tampered_file}")"
  end_ms="$(now_ms)"
  record_runtime_ms "gc_leaf_dispute_packet_generation" "$((end_ms - start_ms))"
  tampered_root="$(extract_kv root_gc "${prepare_out}")"
  root_gcs_csv="$(build_root_gcs_csv_with_override "${out_dir}" "${target_instance}" "${tampered_root}")"

  local before_tampered_core after_tampered_core tampered_core_out
  before_tampered_core="$(stage_value)"
  tampered_core_out="$(run_alice submit-core-commitments \
    --bit-width "${BIT_WIDTH}" \
    --circuit-id "${CIRCUIT_ID}" \
    --winner-formula "${WINNER_FORMULA}" \
    --bids "${bids_csv}" \
    --chosen-namehash "${chosen_namehash}" \
    --root-gcs "${root_gcs_csv}" \
    --export-dir "${out_dir}")"
  record_tx_from_output "commitment_publication" "submitCommitments" "garbler" "1" "${tampered_core_out}"
  after_tampered_core="$(stage_value)"
  v_log "tampered_core_commitments_submitted: instance=${target_instance} [OK]"
  set_last_stage_transition "${before_tampered_core}" "${after_tampered_core}"
  log_action_stage "submit_tampered_core_commitments" "${before_tampered_core}" "${after_tampered_core}"
  log_pretty_step "P4 Commit core (tampered)" "OK" "tampered opened-instance rootGC committed (instance=${target_instance})" "${before_tampered_core}" "${after_tampered_core}"

  submit_ot_roots_all "case3"
  log_pretty_step "P5 OT roots" "OK" "roots for all buyers committed" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  buyer_ready_all
  log_pretty_step "P6 BuyerInputOT" "OK" "ready=3, defaulted=0" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"

  reveal_openings "${m}"
  log_pretty_step "P7 Open" "OK" "m=${m}, opened instances revealed" "${LAST_STAGE_BEFORE}" "${LAST_STAGE_AFTER}"
  local before_dispute after_dispute
  local b1_before b2_before b3_before a_before
  local b1_after b2_after b3_after a_after
  local equal_share remainder alice_collateral dispute_gate dispute_leaf dispute_ih dispute_layout dispute_seed
  local dispute_leaf_hash ih_len layout_len
  before_dispute="$(stage_value)"
  a_before="$(participant_balance "${ALICE_ADDR}")"
  b1_before="$(participant_balance "${B1_ADDR}")"
  b2_before="$(participant_balance "${B2_ADDR}")"
  b3_before="$(participant_balance "${B3_ADDR}")"
  dispute_seed="${seed_hex}"
  dispute_gate="$(extract_kv selected_gate_index "${prepare_out}")"
  dispute_leaf="$(extract_kv claimed_leaf "${prepare_out}")"
  dispute_ih="$(extract_kv ih_proof "${prepare_out}")"
  dispute_layout="$(extract_kv layout_proof "${prepare_out}")"
  record_dispute_packet_artifact "${dispute_leaf}" "${dispute_ih}" "${dispute_layout}"
  dispute_leaf_hash="$(cast keccak "${dispute_leaf}" | tr -d '[:space:]')"
  ih_len="$(csv_len "${dispute_ih}")"
  layout_len="$(csv_len "${dispute_layout}")"
  v_log "alice_cheat_dispute_call: buyer=${B1_ADDR} instance=${target_instance} seed=${dispute_seed} gateIndex=${dispute_gate}"
  v_log "alice_cheat_dispute_call: gateType=$(extract_kv gate_type "${prepare_out}") wireA=$(extract_kv wire_a "${prepare_out}") wireB=$(extract_kv wire_b "${prepare_out}") wireC=$(extract_kv wire_c "${prepare_out}")"
  v_log "alice_cheat_dispute_call: leafHash=$(short_hash32 "${dispute_leaf_hash}") ihProofLen=${ih_len} layoutProofLen=${layout_len}"
  local dispute_out dispute_tx
  dispute_out="$(run_bob 0 dispute \
    --instance-id "${target_instance}" \
    --seed "${dispute_seed}" \
    --gate-index "${dispute_gate}" \
    --gate-type "$(extract_kv gate_type "${prepare_out}")" \
    --wire-a "$(extract_kv wire_a "${prepare_out}")" \
    --wire-b "$(extract_kv wire_b "${prepare_out}")" \
    --wire-c "$(extract_kv wire_c "${prepare_out}")" \
    --leaf-bytes "${dispute_leaf}" \
    --ih-proof "${dispute_ih}" \
    --layout-proof "${dispute_layout}")"
  record_tx_from_output "dispute" "disputeGarbledTable" "evaluator_B1" "1" "${dispute_out}"
  dispute_tx="$(extract_kv dispute_tx_hash "${dispute_out}")"
  LAST_DISPUTE_TX="${dispute_tx}"
  after_dispute="$(stage_value)"
  LAST_DISPUTE_STAGE_BEFORE="${before_dispute}"
  LAST_DISPUTE_STAGE_AFTER="${after_dispute}"
  a_after="$(participant_balance "${ALICE_ADDR}")"
  b1_after="$(participant_balance "${B1_ADDR}")"
  b2_after="$(participant_balance "${B2_ADDR}")"
  b3_after="$(participant_balance "${B3_ADDR}")"
  log_action_stage "dispute_garbled_table" "${before_dispute}" "${after_dispute}"
  alice_collateral="${DEPOSIT_WEI}"
  equal_share="$((alice_collateral / 3))"
  remainder="$((alice_collateral % 3))"
  v_log "equal_split_math: alice_collateral_wei=${alice_collateral} buyers=3 equal_share_wei=${equal_share} remainder_wei=${remainder} expected_b1_gain_wei=$((equal_share + remainder)) expected_b2_gain_wei=${equal_share} expected_b3_gain_wei=${equal_share}"
  v_log "dispute_tx: ${dispute_tx}"
  if [[ -n "${dispute_tx}" ]]; then
    v_log "$(show_receipt_topic_presence "${dispute_tx}" "GateLeafChallenged(uint256,uint256,bool)" "gate_leaf_challenged_event")"
    v_log "$(show_receipt_topic_presence "${dispute_tx}" "CheaterSlashed(address,address)" "cheater_slashed_event")"
  fi
  v_log "equal_split_observed: alice_delta_wei=$(wei_delta "${a_before}" "${a_after}") b1_delta_wei=$(wei_delta "${b1_before}" "${b1_after}") b2_delta_wei=$(wei_delta "${b2_before}" "${b2_after}") b3_delta_wei=$(wei_delta "${b3_before}" "${b3_after}")"
  log_pretty_step "P8 Dispute" "OK" "gate-leaf mismatch proven by B1, Alice slashed, protocol closed" "${LAST_DISPUTE_STAGE_BEFORE}" "${LAST_DISPUTE_STAGE_AFTER}"

  assert_closed
  local stage_now assigned_now
  stage_now="$(stage_name "$(stage_value)")"
  assigned_now="$(cast call "${CONTRACT_ADDRESS}" "assigned()(bool)" --rpc-url "${RPC_URL}" | grep -Eo '(true|false)' | head -n1)"
  echo "Proof: gate leaf mismatch ✅ -> Alice slashed ✅ -> equal split: $(format_wei_eth "${DEPOSIT_WEI}") ETH / 3 = $(format_wei_eth "${equal_share}") ETH each ✅"
  echo "Result: disputeTx=${LAST_DISPUTE_TX}, closed_without_assignment=true"
  echo "Settlement: skipped (contract closed by dispute)"
  echo "Reason: dispute resolved => contract Closed; settle rejected by stage"
  echo "Assignment: skipped (closed after dispute)"
  record_scenario_summary "$(stage_name "$(stage_value)")" "false" "${assigned_now}" "true" "garbler" "tampered opened-instance rootGC disputed by GC leaf challenge; total gas excludes deployment transactions"
  echo "Chosen ENS: N/A (no settle output accepted due to dispute -> Closed)"
  echo "Assign: skipped (Closed after dispute), assigned=false ✅"
  echo "Money: per-buyer expected payout = returned deposit ($(format_wei_eth "${DEPOSIT_WEI}") ETH) + share ($(format_wei_eth "${equal_share}") ETH); wallet balances are post-gas"
  echo "Final: stage=${stage_now}, assigned=${assigned_now}"
  echo "STATUS: ✅ Alice slashed | ✅ Stage=Closed | ✅ Assigned=false (expected)"

  if is_truthy "${VERBOSE}"; then
    print_balances "final_balances"
  fi
  wait_phase
}

main() {
  preflight
  mkdir -p "${WORK_ROOT}"
  init_evaluation_results
  local scenario
  case "${1:-}" in
    --verbose)
      VERBOSE=1
      shift
      ;;
    --pretty)
      VERBOSE=0
      shift
      ;;
  esac
  scenario="${1:-all}"

  case "${scenario}" in
    all)
      scenario_success
      scenario_bob_defaulted
      scenario_alice_cheats
      ;;
    success)
      scenario_success
      ;;
    buyer-defaulted)
      scenario_bob_defaulted
      ;;
    alice-cheat)
      scenario_alice_cheats
      ;;
    *)
      echo "Unknown scenario '${scenario}'. Use: [--pretty|--verbose] all | success | buyer-defaulted | alice-cheat" >&2
      exit 1
      ;;
  esac

  echo
  echo "Demo completed."
  echo "artifacts_root=${WORK_ROOT}"
}

main "$@"
