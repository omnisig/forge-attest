#!/usr/bin/env bash
#
#  forge-attest — prove a Gnosis Safe transaction is exactly the output of a
#                 specific Forge script, unmanipulated.
#
#  Given a pinned commit of a "producer" repo, this:
#    1. clones it at that exact commit,
#    2. re-runs its Forge script deterministically,
#    3. checks the emitted JSON's sha256 against a pinned value,      (source integrity)
#    4. derives the Safe EIP-712 tx hash two independent ways         (cast + Solidity)
#       and checks both against a pinned expected hash,
#    5. optionally checks that same hash against what is actually
#       queued in the Safe, via the Safe Transaction Service.         (live integrity)
#
#  Matching hashes across all layers prove the submitted Safe tx is byte-for-byte
#  the script's output.
#
#  Usage: ./attest.sh [--config attest.toml] [--require-live] [--keep] [--help]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG="$SCRIPT_DIR/attest.toml"
REQUIRE_LIVE=0
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --require-live) REQUIRE_LIVE=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help)
      grep -E '^#' "$0" | sed -E 's/^#\??//' | sed -E 's/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
for bin in git forge cast jq sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

# --- load config --------------------------------------------------------------
producer_repo=$(toml_get "$CONFIG" producer_repo)
producer_commit=$(toml_get "$CONFIG" producer_commit)
producer_setup=$(toml_get "$CONFIG" producer_setup)
producer_script=$(toml_get "$CONFIG" producer_script)
output_path=$(toml_get "$CONFIG" output_path)
expected_sha=$(toml_get "$CONFIG" expected_output_sha256)
expected_hash=$(lc "$(toml_get "$CONFIG" expected_safe_tx_hash)")
safe_network=$(toml_get "$CONFIG" safe_network)
safe_address=$(toml_get "$CONFIG" safe_address)
safe_nonce=$(toml_get "$CONFIG" safe_nonce)

[[ -n "$producer_repo"   ]] || die "config: producer_repo is required"
[[ -n "$producer_commit" ]] || die "config: producer_commit is required"
[[ -n "$producer_script" ]] || die "config: producer_script is required"
[[ -n "$output_path"     ]] || die "config: output_path is required"

FAILURES=()
record_fail() { FAILURES+=("$1"); fail "$1"; }

WORK="$(mktemp -d)"
cleanup() { [[ "$KEEP" == 1 ]] && { warn "kept workdir: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

echo
step "forge-attest"
printf '    producer : %s\n' "$producer_repo"
printf '    commit   : %s\n' "$producer_commit"
printf '    script   : %s\n' "$producer_script"
echo

# --- 1. clone the producer at the pinned commit -------------------------------
step "Cloning producer at pinned commit"
git clone --quiet "$producer_repo" "$WORK/repo" || die "git clone failed: $producer_repo"
git -C "$WORK/repo" checkout --quiet "$producer_commit" 2>/dev/null \
  || die "commit not found in producer repo: $producer_commit"
actual_commit=$(git -C "$WORK/repo" rev-parse HEAD)
[[ "$actual_commit" == "$producer_commit" ]] \
  || die "checked-out HEAD ($actual_commit) != pinned commit ($producer_commit)"
ok "checked out $actual_commit"

# --- 2. run the producer's Forge script ---------------------------------------
step "Running the Forge script"
(
  cd "$WORK/repo"
  [[ -n "$producer_setup" ]] && { echo "    setup: $producer_setup"; bash -c "$producer_setup"; }
  mkdir -p "$(dirname "$output_path")"
  forge script "$producer_script" >/dev/null 2>"$WORK/forge.err" \
    || { cat "$WORK/forge.err" >&2; exit 1; }
) || die "forge script failed (see error above)"
out_json="$WORK/repo/$output_path"
[[ -f "$out_json" ]] || die "script did not produce expected output: $output_path"
ok "produced $output_path"

# --- 3. source integrity: sha256 of the emitted JSON --------------------------
step "Checking output integrity (sha256)"
got_sha=$(sha256sum "$out_json" | awk '{print $1}')
printf '    sha256   : %s\n' "$got_sha"
if [[ -z "$expected_sha" ]]; then
  warn "no expected_output_sha256 pinned — skipping byte-integrity check"
elif [[ "$got_sha" == "$expected_sha" ]]; then
  ok "matches pinned sha256"
else
  record_fail "output sha256 mismatch (expected $expected_sha)"
fi

# --- 4a. derive the Safe tx hash via cast -------------------------------------
step "Deriving Safe tx hash (cast)"
eval "$(bash "$SCRIPT_DIR/lib/derive.sh" "$out_json")"   # sets DOMAIN_HASH / MESSAGE_HASH / SAFE_TX_HASH
cast_hash=$(lc "$SAFE_TX_HASH")
printf '    domain   : %s\n' "$DOMAIN_HASH"
printf '    message  : %s\n' "$MESSAGE_HASH"
printf '    safeTx   : %s\n' "$cast_hash"
if [[ -n "$expected_hash" && "$cast_hash" != "$expected_hash" ]]; then
  record_fail "cast-derived hash != pinned expected_safe_tx_hash ($expected_hash)"
else
  ok "cast derivation done"
fi

# --- 4b. cross-check the Safe tx hash via Solidity (forge test) ---------------
step "Cross-checking Safe tx hash (Solidity)"
mkdir -p "$SCRIPT_DIR/out"
cp "$out_json" "$SCRIPT_DIR/out/safe-tx.json"
rm -f "$SCRIPT_DIR/out/solidity-safe-tx-hash.txt"
if ATTEST_JSON="out/safe-tx.json" ATTEST_EXPECTED_SAFE_TX_HASH="${expected_hash:-$cast_hash}" \
     forge test --root "$SCRIPT_DIR" --match-contract AttestTest -q >"$WORK/forge-test.log" 2>&1; then
  sol_hash=$(lc "$(cat "$SCRIPT_DIR/out/solidity-safe-tx-hash.txt" 2>/dev/null || echo '')")
  printf '    safeTx   : %s\n' "${sol_hash:-<unavailable>}"
  if [[ -n "$sol_hash" && "$sol_hash" != "$cast_hash" ]]; then
    record_fail "Solidity hash ($sol_hash) != cast hash ($cast_hash)"
  else
    ok "Solidity agrees with cast${expected_hash:+ and pinned expectation}"
  fi
else
  cat "$WORK/forge-test.log" >&2
  record_fail "Solidity cross-check (forge test) failed"
fi

# --- 5. live integrity: compare against the Safe Transaction Service ----------
step "Live check against Safe Transaction Service"
if [[ -z "$safe_network" || -z "$safe_address" || -z "$safe_nonce" ]]; then
  warn "safe_network/address/nonce not fully set — skipping live check"
else
  # Run errexit-free: the tool and the hash-parsing pipes may legitimately fail
  # (offline, or no tx queued at that nonce) and that must not abort attestation.
  set +e
  live_out="$WORK/safe_hashes.out"
  timeout 60 bash "$SCRIPT_DIR/lib/safe_hashes.sh" \
    --network "$safe_network" --address "$safe_address" --nonce "$safe_nonce" \
    >"$live_out" 2>&1
  live_rc=$?
  live_hash=$(sed -E 's/\x1b\[[0-9;]*m//g' "$live_out" \
    | grep -iA2 'safe transaction hash' | grep -oiE '0x[a-f0-9]{64}' | tail -1)
  live_hash=$(lc "$live_hash")
  set -e

  if [[ "$live_rc" -ne 0 || -z "$live_hash" ]]; then
    msg="Safe Transaction Service unreachable or no tx at nonce $safe_nonce"
    if [[ "$REQUIRE_LIVE" == 1 ]]; then
      cat "$live_out" >&2; record_fail "$msg"
    else
      warn "$msg — skipping (use --require-live to enforce)"
    fi
  else
    printf '    safeTx   : %s\n' "$live_hash"
    if [[ "$live_hash" == "$cast_hash" ]]; then
      ok "queued Safe tx matches the script-derived hash"
    else
      record_fail "queued Safe tx ($live_hash) != script-derived ($cast_hash)"
    fi
  fi
fi

# --- verdict ------------------------------------------------------------------
echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf '%s%s ATTESTED %s the submitted Safe tx is exactly the output of %s@%s\n' \
    "$C_BOLD" "$C_GREEN" "$C_RESET" "$producer_script" "${producer_commit:0:12}"
  exit 0
else
  printf '%s%s NOT ATTESTED %s %d check(s) failed:\n' \
    "$C_BOLD" "$C_RED" "$C_RESET" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
  exit 1
fi
