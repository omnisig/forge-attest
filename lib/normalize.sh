#!/usr/bin/env bash
#
# normalize.sh — turn *any* supported Safe transaction JSON into forge-attest's
#                canonical single-SafeTx form, so every downstream check (sha256,
#                cast derivation, Solidity cross-check, live comparison) has one
#                stable thing to look at.
#
# Supported input formats (auto-detected, override with --format):
#
#   safe-tx      A flat object already carrying the full EIP-712 SafeTx field set
#                (what forge-attest's own example producer emits).
#
#   tx-builder   A Safe{Wallet} Transaction Builder batch — the shape emitted by
#                FraxFinance's `SafeTxHelper.writeTxs` and by the Safe UI's
#                "export batch":
#                  { version, chainId, createdAt, meta, transactions: [
#                      { to, value, data, operation? }, ... ] }
#                A batch carries no Safe address, nonce or gas fields, so those
#                must be supplied via flags. Multi-transaction batches are packed
#                into a single `multiSend(bytes)` delegatecall exactly as the Safe
#                UI does, which is what the owners actually sign.
#
#   tx-array     A bare JSON array of { to, value, data, operation? } — same
#                treatment as tx-builder, with chainId supplied via flags.
#
# The canonical output is deterministic: fixed key order, all scalars quoted, all
# hex lowercased. Its sha256 is therefore stable across producers even when the
# source JSON carries volatile metadata (`createdAt`, `meta`, key ordering,
# address checksum casing) — see --print-digest.
#
# Usage:
#   normalize.sh --input <json> [options] > canonical.json
#
# Options:
#   --input PATH            source JSON (required)
#   --format FMT            auto (default) | safe-tx | tx-builder | tx-array
#   --safe ADDR             Safe address        (required for batches)
#   --nonce N               Safe nonce          (required for batches)
#   --chain-id N            chain id            (required if absent from JSON)
#   --safe-version V        Safe contract version, default 1.3.0
#   --batch-mode MODE       auto (default) | multisend | single
#                             auto      -> multiSend when >1 tx, direct call when 1
#                             multisend -> always wrap, even a 1-tx batch
#                             single    -> require exactly 1 tx, send it directly
#   --multisend ADDR        MultiSend contract to delegatecall (default: the
#                           canonical MultiSendCallOnly for --safe-version)
#   --safe-tx-gas N         default 0
#   --base-gas N            default 0
#   --gas-price N           default 0
#   --gas-token ADDR        default 0x0
#   --refund-receiver ADDR  default 0x0
#   --print-digest          also print `CANONICAL_SHA256=<sha>` on stderr
#   --summary               print a human-readable batch summary on stderr
#
# Where a value is present in BOTH the JSON and the flags, the two must agree —
# a mismatch is a tampering signal and is a hard error, never a silent override.
set -euo pipefail

NORMALIZE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT=""; FORMAT="auto"
SAFE=""; NONCE=""; CHAIN_ID=""; SAFE_VERSION=""
BATCH_MODE="auto"; MULTISEND=""
SAFE_TX_GAS=""; BASE_GAS=""; GAS_PRICE=""; GAS_TOKEN=""; REFUND_RECEIVER=""
PRINT_DIGEST=0; SUMMARY=0

# Canonical MultiSendCallOnly deployments — the contract Safe{Wallet} uses to
# execute Transaction Builder batches.
MULTISEND_CALL_ONLY_130="0x40a2accbd92bca938b02010e17a5b8929b49130d"
MULTISEND_CALL_ONLY_141="0x9641d764fc13c8b624c04430c7356c1c7c8102e2"
MULTISEND_CALL_ONLY_150="0xa83c336b20401af773b6219ba5027174338d1836"
# Chain-specific CallOnly deployments. Listed so the delegatecall guard below
# recognises them: missing one silently re-allows what the guard exists to catch.
MULTISEND_CALL_ONLY_130_EIP155="0xa1dabef33b3b82c7814b6d82a79e50f4ac44102b"
MULTISEND_CALL_ONLY_130_ZKSYNC="0xf220d3b4dfb23c4ade8c88e526c1353abacbc38f"
MULTISEND_CALL_ONLY_141_ZKSYNC="0x0408ef011960d02349d50286d20531229bcef773"
is_call_only() {
  case "$1" in
    "$MULTISEND_CALL_ONLY_130"|"$MULTISEND_CALL_ONLY_130_EIP155"|"$MULTISEND_CALL_ONLY_130_ZKSYNC"\
      |"$MULTISEND_CALL_ONLY_141"|"$MULTISEND_CALL_ONLY_141_ZKSYNC"|"$MULTISEND_CALL_ONLY_150") return 0 ;;
    *) return 1 ;;
  esac
}

die() { printf 'normalize.sh: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)           INPUT="$2"; shift 2 ;;
    --format)          FORMAT="$2"; shift 2 ;;
    --safe)            SAFE="$2"; shift 2 ;;
    --nonce)           NONCE="$2"; shift 2 ;;
    --chain-id)        CHAIN_ID="$2"; shift 2 ;;
    --safe-version)    SAFE_VERSION="$2"; shift 2 ;;
    --batch-mode)      BATCH_MODE="$2"; shift 2 ;;
    --multisend)       MULTISEND="$2"; shift 2 ;;
    --safe-tx-gas)     SAFE_TX_GAS="$2"; shift 2 ;;
    --base-gas)        BASE_GAS="$2"; shift 2 ;;
    --gas-price)       GAS_PRICE="$2"; shift 2 ;;
    --gas-token)       GAS_TOKEN="$2"; shift 2 ;;
    --refund-receiver) REFUND_RECEIVER="$2"; shift 2 ;;
    --print-digest)    PRINT_DIGEST=1; shift ;;
    --summary)         SUMMARY=1; shift ;;
    -h|--help)         grep -E '^#' "$0" | sed -E 's/^#\??//' | sed -E 's/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$INPUT" ]] || die "--input is required"
[[ -f "$INPUT" ]] || die "no such file: $INPUT"
jq -e . "$INPUT" >/dev/null 2>&1 || die "not valid JSON: $INPUT"

lower()   { printf '%s' "${1,,}"; }
strip0x() { local v="${1#0x}"; printf '%s' "${v#0X}"; }

# Normalise an address to lowercase 0x + 40 hex, rejecting anything else.
norm_addr() {
  local a; a=$(lower "${1:-}")
  [[ "$a" =~ ^0x[0-9a-f]{40}$ ]] || die "not a 20-byte address: ${1:-<empty>}"
  printf '%s' "$a"
}

# Normalise hex data to lowercase 0x + even-length hex ("" / null -> 0x).
norm_data() {
  local d="${1:-}"
  if [[ -z "$d" || "$d" == "null" ]]; then printf '0x'; return; fi
  d=$(lower "$d")
  [[ "$d" == 0x* ]] || d="0x$d"
  [[ "$d" =~ ^0x([0-9a-f]{2})*$ ]] || die "not even-length hex data: $1"
  printf '%s' "$d"
}

# Normalise an integer given as a decimal string, a JSON number, or 0x-hex.
norm_uint() {
  local n="${1:-}"
  if [[ -z "$n" || "$n" == "null" ]]; then printf '0'; return; fi
  if [[ "$n" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
    n=$(cast to-dec "$n") || die "cannot parse integer: $1"
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || die "not a non-negative integer: $1"
  printf '%s' "$n"
}

# Config vs JSON reconciliation: both may supply a value, but they must agree.
# Silently preferring one over the other would hide exactly the tampering this
# tool exists to detect.
reconcile() {
  local what="$1" from_json="${2:-}" from_flag="${3:-}" jn fn
  jn=$(lower "$from_json"); fn=$(lower "$from_flag")
  [[ "$jn" == "null" ]] && jn=""
  if [[ -n "$jn" && -n "$fn" && "$jn" != "$fn" ]]; then
    die "$what mismatch: JSON says '$from_json' but config says '$from_flag'"
  fi
  printf '%s' "${jn:-$fn}"
}

J=$(cat "$INPUT")
jq_root() { printf '%s' "$J" | jq "$@"; }
jget() { printf '%s' "$J" | jq -r "$1 // empty" 2>/dev/null || true; }

# --- format detection ---------------------------------------------------------
if [[ "$FORMAT" == "auto" ]]; then
  root_type=$(jq_root -r 'type')
  if [[ "$root_type" == "array" ]]; then
    FORMAT="tx-array"
  elif [[ "$root_type" == "object" && "$(jq_root -r '.transactions | type // "none"' 2>/dev/null || true)" == "array" ]]; then
    FORMAT="tx-builder"
  elif [[ "$root_type" == "object" && -n "$(jget '.to')" ]]; then
    FORMAT="safe-tx"
  else
    die "cannot detect input format; pass --format safe-tx|tx-builder|tx-array"
  fi
fi

case "$FORMAT" in safe-tx|tx-builder|tx-array) ;; *) die "unknown --format: $FORMAT" ;; esac
case "$BATCH_MODE" in auto|multisend|single) ;; *) die "unknown --batch-mode: $BATCH_MODE" ;; esac

# --- gather the Safe-level binding (identical for every format) ---------------
# A Transaction Builder file can name the Safe it was built for; the schema slot
# is `meta.createdFromSafeAddress`. When a producer fills it in, the file binds
# itself and --safe becomes a cross-check rather than a required input.
json_safe=$(jget '.safe')
[[ -n "$json_safe" ]] || json_safe=$(jget '.meta.createdFromSafeAddress')
safe=$(reconcile "safe address" "$json_safe" "$SAFE")
nonce=$(reconcile "nonce" "$(jget '.nonce')" "$NONCE")
chain_id=$(reconcile "chainId" "$(jget '.chainId')" "$CHAIN_ID")
safe_version=$(reconcile "safeVersion" "$(jget '.safeVersion')" "$SAFE_VERSION")
[[ -n "$safe_version" ]] || safe_version="1.3.0"

[[ -n "$safe"     ]] || die "no Safe address: absent from the JSON, pass --safe"
[[ -n "$nonce"    ]] || die "no Safe nonce: absent from the JSON, pass --nonce"
[[ -n "$chain_id" ]] || die "no chainId: absent from the JSON, pass --chain-id"

safe=$(norm_addr "$safe")
nonce=$(norm_uint "$nonce")
chain_id=$(norm_uint "$chain_id")

safe_tx_gas=$(norm_uint "$(reconcile "safeTxGas" "$(jget '.safeTxGas')" "$SAFE_TX_GAS")")
base_gas=$(norm_uint "$(reconcile "baseGas" "$(jget '.baseGas')" "$BASE_GAS")")
gas_price=$(norm_uint "$(reconcile "gasPrice" "$(jget '.gasPrice')" "$GAS_PRICE")")
gas_token=$(reconcile "gasToken" "$(jget '.gasToken')" "$GAS_TOKEN")
refund_receiver=$(reconcile "refundReceiver" "$(jget '.refundReceiver')" "$REFUND_RECEIVER")
gas_token=$(norm_addr "${gas_token:-0x0000000000000000000000000000000000000000}")
refund_receiver=$(norm_addr "${refund_receiver:-0x0000000000000000000000000000000000000000}")

# --- resolve the payload (to / value / data / operation) ----------------------
if [[ "$FORMAT" == "safe-tx" ]]; then
  to=$(norm_addr "$(jget '.to')")
  value=$(norm_uint "$(jq_root -r '(.value // 0) | tostring')")
  data=$(norm_data "$(jq_root -r '(.data // "0x") | tostring')")
  operation=$(norm_uint "$(jq_root -r '(.operation // 0) | tostring')")
  [[ "$operation" == "0" || "$operation" == "1" ]] \
    || die "operation must be 0 (CALL) or 1 (DELEGATECALL), got $operation"
  tx_count=1
  batch_json='[]'
else
  txs_expr='.transactions'
  [[ "$FORMAT" == "tx-array" ]] && txs_expr='.'

  # Pull the inner transactions into a normalised array in one jq pass, so a
  # malformed entry fails loudly instead of half-encoding a batch.
  batch_json=$(jq_root -c "
    [ $txs_expr[]
      | { to:        (.to // error(\"batch transaction is missing 'to'\")),
          value:     ((.value // 0) | tostring),
          data:      ((.data // \"0x\") | tostring),
          operation: ((.operation // 0) | tostring),
          method:    (.contractMethod // null) } ]")

  tx_count=$(printf '%s' "$batch_json" | jq 'length')
  (( tx_count > 0 )) || die "batch contains no transactions"

  # A UI-exported batch may describe a call as an ABI method + inputs with a null
  # `data`. Encoding that needs the target ABI, which is out of scope — refuse
  # rather than silently attest an empty calldata.
  for (( i = 0; i < tx_count; i++ )); do
    m=$(printf '%s' "$batch_json" | jq -r ".[$i].method // empty")
    d=$(printf '%s' "$batch_json" | jq -r ".[$i].data")
    if [[ -n "$m" && ( "$d" == "null" || "$d" == "0x" || -z "$d" ) ]]; then
      die "transaction #$i has a contractMethod but no encoded 'data'; re-export the batch with encoded calldata"
    fi
  done

  wrap=0
  case "$BATCH_MODE" in
    multisend) wrap=1 ;;
    single)    (( tx_count == 1 )) || die "--batch-mode single, but the batch holds $tx_count transactions" ;;
    auto)      if (( tx_count > 1 )); then wrap=1; fi ;;
  esac

  if (( wrap == 0 )); then
    to=$(norm_addr "$(printf '%s' "$batch_json" | jq -r '.[0].to')")
    value=$(norm_uint "$(printf '%s' "$batch_json" | jq -r '.[0].value')")
    data=$(norm_data "$(printf '%s' "$batch_json" | jq -r '.[0].data')")
    operation=$(norm_uint "$(printf '%s' "$batch_json" | jq -r '.[0].operation')")
    [[ "$operation" == "0" || "$operation" == "1" ]] || die "operation must be 0 or 1, got $operation"
  else
    # Only versions whose deployment address we actually know are mapped. Guessing
    # for an unknown version would silently produce a `to` the Safe never uses — a
    # wrong hash that looks authoritative. test/SafeTx.sol implements exactly this
    # mapping; the two must not drift, or the independent derivations stop being a
    # check on each other.
    if [[ -z "$MULTISEND" ]]; then
      case "$safe_version" in
        1.3|1.3.*) MULTISEND="$MULTISEND_CALL_ONLY_130"; ms_key="1.3.0" ;;
        1.4|1.4.*) MULTISEND="$MULTISEND_CALL_ONLY_141"; ms_key="1.4.1" ;;
        1.5|1.5.*) MULTISEND="$MULTISEND_CALL_ONLY_150"; ms_key="1.5.0" ;;
        *) die "no known MultiSendCallOnly for Safe $safe_version; pass --multisend explicitly" ;;
      esac

      # The canonical address is not universal. On some chains it is not deployed
      # at all, and on the zkSync-family chains a different-bytecode deployment
      # exists that is the one Safe{Wallet} actually uses. Defaulting there would
      # produce a `to` the Safe never calls — a wrong hash that looks authoritative.
      # No existence gate: a missing table means the guard is not running, which
      # must be loud rather than quietly skipped. test/SafeTx.sol does the same.
      exceptions="$NORMALIZE_DIR/multisend-exceptions.json"
      [[ -f "$exceptions" ]] || die "missing $exceptions — cannot check whether chain $chain_id uses the canonical MultiSendCallOnly"
      if [[ "$(jq -r --arg v "$ms_key" --argjson c "$chain_id" \
                 '((.[$v] // []) | index($c)) != null' "$exceptions")" == "true" ]]; then
        die "chain $chain_id does not use the canonical MultiSendCallOnly for Safe $safe_version; pass --multisend explicitly (see lib/multisend-exceptions.json)"
      fi
    fi
    multisend=$(norm_addr "$MULTISEND")

    # MultiSend payload: for each tx, packed(uint8 operation, address to,
    # uint256 value, uint256 dataLength, bytes data).
    packed=""
    for (( i = 0; i < tx_count; i++ )); do
      t_to=$(norm_addr "$(printf '%s' "$batch_json" | jq -r ".[$i].to")")
      t_value=$(norm_uint "$(printf '%s' "$batch_json" | jq -r ".[$i].value")")
      t_data=$(norm_data "$(printf '%s' "$batch_json" | jq -r ".[$i].data")")
      t_op=$(norm_uint "$(printf '%s' "$batch_json" | jq -r ".[$i].operation")")

      case "$t_op" in
        0) ;;
        1)
          if is_call_only "$multisend"; then
            die "transaction #$i is a DELEGATECALL, which MultiSendCallOnly rejects; pass --multisend <MultiSend address>"
          fi ;;
        *) die "transaction #$i has operation $t_op; expected 0 (CALL) or 1 (DELEGATECALL)" ;;
      esac

      data_len=$(( (${#t_data} - 2) / 2 ))
      packed+=$(printf '%02x' "$t_op")
      packed+=$(strip0x "$t_to")
      packed+=$(strip0x "$(cast to-uint256 "$t_value")")
      packed+=$(strip0x "$(cast to-uint256 "$data_len")")
      packed+=$(strip0x "$t_data")
    done

    to="$multisend"
    value="0"
    data=$(lower "$(cast calldata 'multiSend(bytes)' "0x$packed")")
    operation="1"   # MultiSend is always executed as a DELEGATECALL from the Safe
  fi
fi

# --- emit the canonical SafeTx ------------------------------------------------
# Fixed key order, every scalar quoted (large integers survive JSON intact), all
# hex lowercase. This is the byte-for-byte artifact whose sha256 gets pinned.
canonical=$(jq -n \
  --arg safe "$safe" --arg chainId "$chain_id" --arg safeVersion "$safe_version" \
  --arg to "$to" --arg value "$value" --arg data "$data" --arg operation "$operation" \
  --arg safeTxGas "$safe_tx_gas" --arg baseGas "$base_gas" --arg gasPrice "$gas_price" \
  --arg gasToken "$gas_token" --arg refundReceiver "$refund_receiver" --arg nonce "$nonce" \
  '{safe:$safe, chainId:$chainId, safeVersion:$safeVersion, to:$to, value:$value,
    data:$data, operation:$operation, safeTxGas:$safeTxGas, baseGas:$baseGas,
    gasPrice:$gasPrice, gasToken:$gasToken, refundReceiver:$refundReceiver, nonce:$nonce}')

if [[ "$SUMMARY" == 1 ]]; then
  {
    printf '    format   : %s\n' "$FORMAT"
    printf '    inner tx : %s\n' "$tx_count"
    if [[ "$FORMAT" != "safe-tx" ]]; then
      for (( i = 0; i < tx_count; i++ )); do
        s_to=$(printf '%s' "$batch_json" | jq -r ".[$i].to")
        s_val=$(printf '%s' "$batch_json" | jq -r ".[$i].value")
        s_data=$(norm_data "$(printf '%s' "$batch_json" | jq -r ".[$i].data")")
        printf '      [%d] %s value=%s selector=%s (%d bytes)\n' \
          "$i" "$(lower "$s_to")" "$s_val" "${s_data:0:10}" "$(( (${#s_data} - 2) / 2 ))"
      done
    fi
    printf '    signs as : %s operation=%s\n' "$to" "$operation"
  } >&2
fi

if [[ "$PRINT_DIGEST" == 1 ]]; then
  printf 'CANONICAL_SHA256=%s\n' \
    "$(printf '%s\n' "$canonical" | sha256sum | awk '{print $1}')" >&2
fi

printf '%s\n' "$canonical"
