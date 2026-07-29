#!/usr/bin/env bash
#
# Shell-side test suite for forge-attest.
#
#   1. lib/normalize.sh — format detection, canonicalisation, guard rails
#   2. cast vs Solidity — the two hash derivations must agree on every fixture
#   3. attest.sh        — a full end-to-end run against a synthetic producer repo
#                         that emits a Transaction Builder batch
#
# Usage: test/shell/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$ROOT/test/fixtures"
NORMALIZE="$ROOT/lib/normalize.sh"
DERIVE="$ROOT/lib/derive.sh"

SAFE="0x111CEEee040739fD91D29C34C33E6B3E112F2177"
NONCE="42"

PASS=0
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else GREEN=; RED=; BOLD=; RESET=; fi

pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
group() { printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }

assert_eq() { # what got want
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n      got  '"$2"$'\n      want '"$3"; fi
}
assert_ne() { # what a b
  if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1 (both were $2)"; fi
}
assert_contains() { # what haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"$'\n      output: '"$2"; fi
}

# normalize <fixture> [extra args...] -> canonical JSON on stdout
normalize() {
  local f="$1"; shift
  bash "$NORMALIZE" --input "$FIX/$f" --safe "$SAFE" --nonce "$NONCE" "$@" 2>"$TMP/err"
}

# normalize_err <fixture> [extra args...] -> stderr, expects failure
normalize_err() {
  local f="$1"; shift
  bash "$NORMALIZE" --input "$FIX/$f" --safe "$SAFE" --nonce "$NONCE" "$@" 2>&1 >/dev/null
}

canonical_sha() { sha256sum | awk '{print $1}'; }

safe_tx_hash() { # <canonical json path>
  bash "$DERIVE" "$1" | grep '^SAFE_TX_HASH=' | cut -d= -f2
}

# ---------------------------------------------------------------- 1. normalize

group "normalize.sh: format detection"

fmt() { normalize "$1" "${@:2}" >/dev/null; sed -n 's/^ *format *: *//p' "$TMP/err"; }

assert_eq "detects tx-builder (Frax SafeTxHelper output)" \
  "$(fmt tx-builder-frax-optimism.json --summary)" "tx-builder"
assert_eq "detects a bare transaction array" \
  "$(fmt tx-array.json --summary --chain-id 1)" "tx-array"
assert_eq "detects a flat SafeTx object" \
  "$(fmt safe-tx-single.json --summary)" "safe-tx"

group "normalize.sh: canonical form"

canon_frax="$TMP/frax.json"
normalize tx-builder-frax-optimism.json >"$canon_frax"

assert_eq "chainId is taken from the batch" \
  "$(jq -r .chainId "$canon_frax")" "10"
assert_eq "a 6-tx batch is signed as a delegatecall" \
  "$(jq -r .operation "$canon_frax")" "1"
assert_eq "…into MultiSendCallOnly 1.3.0" \
  "$(jq -r .to "$canon_frax")" "0x40a2accbd92bca938b02010e17a5b8929b49130d"
assert_eq "…with multiSend(bytes) calldata" \
  "$(jq -r .data "$canon_frax" | cut -c1-10)" "0x8d80ff0a"
assert_eq "the Safe binding comes from config" \
  "$(jq -r '[.safe, .nonce] | join(" ")' "$canon_frax")" \
  "$(printf '%s 42' "${SAFE,,}")"
assert_eq "every canonical scalar is a quoted string" \
  "$(jq -r '[.[] | type] | unique | join(",")' "$canon_frax")" "string"
assert_eq "canonical key order is fixed" \
  "$(jq -r 'keys_unsorted | join(",")' "$canon_frax")" \
  "safe,chainId,safeVersion,to,value,data,operation,safeTxGas,baseGas,gasPrice,gasToken,refundReceiver,nonce"

# The property the whole design rests on: `createdAt`, `meta`, key order, address
# checksum casing, hex casing and string-vs-number scalars are all presentation,
# and must not move the bytes that get signed.
assert_eq "volatile metadata does not change the canonical digest" \
  "$(normalize tx-builder-frax-optimism-restamped.json | canonical_sha)" \
  "$(cat "$canon_frax" | canonical_sha)"

assert_eq "a single-transaction batch is not wrapped in multiSend" \
  "$(normalize tx-builder-single.json | jq -r '[.to, .operation] | join(" ")')" \
  "0x000000000000000000000000000000000000dead 0"
assert_eq "null data becomes empty calldata" \
  "$(normalize tx-builder-single.json | jq -r .data)" "0x"
assert_eq "--batch-mode multisend wraps even a single transaction" \
  "$(normalize tx-builder-single.json --batch-mode multisend | jq -r .operation)" "1"
assert_eq "Safe 1.4.x selects the 1.4.1 MultiSendCallOnly" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.4.1 | jq -r .to)" \
  "0x9641d764fc13c8b624c04430c7356c1c7c8102e2"

# The version -> MultiSend mapping must cover exactly the versions test/SafeTx.sol
# covers. A version one side maps and the other doesn't means the two derivations
# pick different `to` addresses and silently disagree.
assert_eq "Safe 1.5.x selects the 1.5.0 MultiSendCallOnly" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.5.0 | jq -r .to)" \
  "0xa83c336b20401af773b6219ba5027174338d1836"
# The canonical MultiSendCallOnly is not universal; guessing it on a chain that
# uses a different deployment yields a `to` the Safe never calls.
assert_contains "zkSync Era refuses the canonical MultiSend default" \
  "$(normalize_err tx-builder-zksync-era.json)" \
  "chain 324 does not use the canonical MultiSendCallOnly"
assert_eq "…but an explicit address is honoured" \
  "$(normalize tx-builder-zksync-era.json --multisend 0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F | jq -r .to)" \
  "0xf220d3b4dfb23c4ade8c88e526c1353abacbc38f"
assert_eq "Safe 1.5.0 has no divergent chains" \
  "$(normalize tx-builder-zksync-era.json --safe-version 1.5.0 | jq -r .to)" \
  "0xa83c336b20401af773b6219ba5027174338d1836"

assert_contains "an unknown Safe version is refused, not guessed at" \
  "$(normalize_err tx-builder-frax-optimism.json --safe-version 1.9.9)" \
  "no known MultiSendCallOnly for Safe 1.9.9"
assert_eq "…but works once the address is named" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.9.9 \
       --multisend 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 | jq -r .to)" \
  "0x9641d764fc13c8b624c04430c7356c1c7c8102e2"

# Gas/refund fields are hash inputs that no batch format carries, so they come
# from config — and must reach both derivations, not just this one.
assert_eq "gas fields land in the canonical form" \
  "$(normalize tx-builder-frax-optimism.json --gas-price 1000 --safe-tx-gas 50000 \
       | jq -r '[.gasPrice, .safeTxGas] | join(" ")')" \
  "1000 50000"

# The packed payload commits to each entry's length, so the Frax batch encodes to
# 6 * (1 + 20 + 32 + 32 + 164) = 1494 bytes. In the `multiSend(bytes)` calldata
# that length sits in the second word: "0x" + selector(8) + offset(64), so chars
# 75..138.
assert_eq "multiSend payload length is 6 * 249 bytes" \
  "$(jq -r .data "$canon_frax" | cut -c75-138 | sed 's/^0*//')" "5d6"

group "normalize.sh: a batch that binds itself"

# The Transaction Builder schema has a slot for the Safe a batch was built for.
# When a producer fills it in, --safe stops being a required input.
assert_eq "the Safe is taken from meta.createdFromSafeAddress" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-self-binding.json" --nonce 42 | jq -r .safe)" \
  "${SAFE,,}"
assert_eq "a config Safe that agrees is accepted" \
  "$(normalize tx-builder-self-binding.json | jq -r .safe)" "${SAFE,,}"
assert_contains "a config Safe that contradicts the file is rejected" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-self-binding.json" --nonce 42 \
       --safe 0x000000000000000000000000000000000000b0b0 2>&1 >/dev/null)" \
  "safe address mismatch"
assert_contains "a file declaring no Safe still needs one" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --nonce 42 2>&1 >/dev/null)" \
  "no Safe address"

group "normalize.sh: guard rails"

assert_contains "rejects a contractMethod entry with no encoded data" \
  "$(normalize_err tx-builder-contract-method.json)" "contractMethod but no encoded 'data'"
assert_contains "rejects an inner delegatecall under MultiSendCallOnly" \
  "$(normalize_err tx-builder-delegatecall.json)" "MultiSendCallOnly rejects"
assert_contains "accepts an inner delegatecall with an explicit MultiSend" \
  "$(normalize tx-builder-delegatecall.json --multisend 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761 | jq -r .to)" \
  "0xa238cbeb142c10ef7ad8442c6d1f9e89e07e7761"
assert_contains "rejects --batch-mode single on a multi-transaction batch" \
  "$(normalize_err tx-builder-frax-optimism.json --batch-mode single)" "but the batch holds 6 transactions"
assert_contains "requires a Safe address for batches" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --nonce 1 2>&1 >/dev/null)" \
  "no Safe address"
assert_contains "requires a nonce for batches" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --safe "$SAFE" 2>&1 >/dev/null)" \
  "no Safe nonce"
assert_contains "requires a chainId when the JSON has none" \
  "$(normalize_err tx-array.json)" "no chainId"

# A config value that disagrees with the JSON is a tampering signal, not a
# preference to be silently resolved.
assert_contains "refuses to override a value the JSON already carries" \
  "$(normalize_err tx-builder-frax-optimism.json --chain-id 1)" "chainId mismatch"
assert_contains "accepts a config value that agrees with the JSON" \
  "$(normalize tx-builder-frax-optimism.json --chain-id 10 | jq -r .chainId)" "10"

assert_contains "rejects malformed JSON" \
  "$(printf 'not json' >"$TMP/bad.json"; bash "$NORMALIZE" --input "$TMP/bad.json" 2>&1 >/dev/null)" \
  "not valid JSON"
assert_contains "rejects an empty batch" \
  "$(printf '{"chainId":1,"transactions":[]}' >"$TMP/empty.json"; \
     bash "$NORMALIZE" --input "$TMP/empty.json" --safe "$SAFE" --nonce 1 2>&1 >/dev/null)" \
  "no transactions"

# ------------------------------------------------- 2. cast vs Solidity agreement

group "cast vs Solidity: independent derivations must agree"

mkdir -p "$ROOT/out"

cross_check() { # <label> <fixture> [normalize args...]
  local label="$1" fixture="$2"; shift 2
  local canon="$TMP/cross.json"
  if ! normalize "$fixture" "$@" >"$canon"; then
    fail "$label (normalize failed: $(cat "$TMP/err"))"; return
  fi
  local cast_hash; cast_hash=$(safe_tx_hash "$canon")

  # Point the Solidity cross-check at the *raw* fixture, exactly as attest.sh
  # does: it must fold the batch itself rather than trusting normalize.sh.
  cp "$FIX/$fixture" "$ROOT/out/producer-tx.json"
  rm -f "$ROOT/out/solidity-safe-tx-hash.txt"

  # Mirror the normalize flags into the env attest.sh sets, so the Solidity side
  # is given exactly the same binding and any divergence is a real one.
  local force=""; [[ " $* " == *" --batch-mode multisend "* ]] && force=1
  local version=""; [[ " $* " == *" --safe-version "* ]] && version="1.4.1"
  local chain=""; [[ "$fixture" == "tx-array.json" ]] && chain="1"
  local multisend=""
  [[ " $* " == *" --multisend "* ]] && multisend="0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761"
  local gas_price=""; [[ " $* " == *" --gas-price "* ]] && gas_price="1000"
  local safe_tx_gas=""; [[ " $* " == *" --safe-tx-gas "* ]] && safe_tx_gas="50000"

  if ! ATTEST_JSON="out/producer-tx.json" \
       ATTEST_EXPECTED_SAFE_TX_HASH="$cast_hash" \
       ATTEST_SAFE="$SAFE" ATTEST_NONCE="$NONCE" ATTEST_CHAIN_ID="$chain" \
       ATTEST_SAFE_VERSION="$version" ATTEST_MULTISEND="$multisend" \
       ATTEST_FORCE_MULTISEND="$force" \
       ATTEST_GAS_PRICE="$gas_price" ATTEST_SAFE_TX_GAS="$safe_tx_gas" \
       forge test --root "$ROOT" --match-contract AttestTest -q >"$TMP/forge.log" 2>&1; then
    fail "$label"$'\n'"$(sed 's/^/      /' "$TMP/forge.log")"
    return
  fi
  assert_eq "$label" "$(tr 'A-Z' 'a-z' <"$ROOT/out/solidity-safe-tx-hash.txt")" "$cast_hash"
}

cross_check "flat SafeTx"                     safe-tx-single.json
cross_check "Frax Transaction Builder batch"  tx-builder-frax-optimism.json
cross_check "the same batch, re-stamped"      tx-builder-frax-optimism-restamped.json
cross_check "single-transaction batch"        tx-builder-single.json
cross_check "single-transaction batch, forced multiSend" \
                                              tx-builder-single.json --batch-mode multisend
cross_check "bare transaction array"          tx-array.json --chain-id 1
cross_check "batch declaring its own Safe"    tx-builder-self-binding.json
cross_check "non-zero gas fields from config" tx-builder-frax-optimism.json --gas-price 1000 --safe-tx-gas 50000
cross_check "Safe 1.4.1 MultiSendCallOnly"    tx-builder-frax-optimism.json --safe-version 1.4.1
cross_check "explicit MultiSend, inner delegatecall" \
                                              tx-builder-delegatecall.json --multisend 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761

# The pinned hash for the Frax batch, restated here so a change to *either*
# implementation has to be a deliberate edit to this file.
assert_eq "Frax batch hashes to the pinned value" \
  "$(safe_tx_hash "$canon_frax")" \
  "0xa55af81f3e8e946ba3989ba04fe1fa0685a104114c479e05f0367bba8c712680"

# ------------------------------------------------------------ 3. end-to-end run

group "attest.sh: end-to-end against a batch-emitting producer"

PRODUCER="$TMP/producer"
mkdir -p "$PRODUCER/script"
cat >"$PRODUCER/foundry.toml" <<'EOF'
[profile.default]
src = "script"
script = "script"
out = "forge-out"
libs = []
solc = "0.8.28"
fs_permissions = [{ access = "read-write", path = "./out" }]
EOF
# A miniature stand-in for FraxFinance's SafeTxHelper: same output shape, and the
# same volatile `createdAt` stamp that makes a byte-exact sha256 useless.
cat >"$PRODUCER/script/BuildBatch.s.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface Vm {
    function toString(address value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
    function toString(bytes calldata value) external pure returns (string memory);
    function projectRoot() external view returns (string memory);
    function createDir(string calldata path, bool recursive) external;
    function writeFile(string calldata path, string calldata data) external;
}

contract BuildBatch {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        address token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        bytes memory a = abi.encodeWithSignature("approve(address,uint256)", address(0xBEEF), 1e6);
        bytes memory b = abi.encodeWithSignature("transfer(address,uint256)", address(0xDEAD), 1e6);

        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": 1,\n  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ',\n  "meta": { "name": "Transactions Batch", "description": "" },\n  "transactions": [\n',
            '    { "to": "', vm.toString(token), '", "value": "0", "data": "', vm.toString(a), '", "operation": "0" },\n',
            '    { "to": "', vm.toString(token), '", "value": "0", "data": "', vm.toString(b), '", "operation": "0" }\n',
            "  ]\n}\n"
        );

        string memory outDir = string.concat(vm.projectRoot(), "/out");
        vm.createDir(outDir, true);
        vm.writeFile(string.concat(outDir, "/batch.json"), json);
    }
}
EOF
printf 'out/\nforge-out/\ncache/\n' >"$PRODUCER/.gitignore"
(
  cd "$PRODUCER"
  git init --quiet
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t commit --quiet -m "batch producer"
) >/dev/null 2>&1
PRODUCER_COMMIT=$(git -C "$PRODUCER" rev-parse HEAD)

# Derive the expectations the way an operator would the first time round.
(cd "$PRODUCER" && forge script script/BuildBatch.s.sol:BuildBatch >/dev/null 2>&1)
E2E_CANON="$TMP/e2e-canonical.json"
bash "$NORMALIZE" --input "$PRODUCER/out/batch.json" --safe "$SAFE" --nonce 7 >"$E2E_CANON" 2>/dev/null
E2E_SHA=$(canonical_sha <"$E2E_CANON")
E2E_HASH=$(safe_tx_hash "$E2E_CANON")

write_config() { # <path> <canonical sha> <expected hash>
  cat >"$1" <<EOF
producer_repo   = "file://$PRODUCER"
producer_commit = "$PRODUCER_COMMIT"
producer_setup  = ""
producer_script = "script/BuildBatch.s.sol:BuildBatch"
output_path     = "out/batch.json"
input_format    = "auto"
batch_mode      = "auto"
safe_version    = "1.3.0"
expected_output_sha256    = ""
expected_canonical_sha256 = "$2"
expected_safe_tx_hash     = "$3"
safe_network = ""
safe_address = "$SAFE"
safe_nonce   = "7"
EOF
}

write_config "$TMP/e2e.toml" "$E2E_SHA" "$E2E_HASH"
e2e_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e.toml" 2>&1)
e2e_rc=$?
if [[ $e2e_rc -eq 0 ]]; then pass "a correct claim is ATTESTED"
else fail "a correct claim is ATTESTED"$'\n'"$(sed 's/^/      /' <<<"$e2e_out")"; fi
assert_contains "…and says so" "$e2e_out" "ATTESTED"
assert_contains "…reporting the detected format" "$e2e_out" "format   : tx-builder"
assert_contains "…and the inner transaction count" "$e2e_out" "inner tx : 2"
assert_contains "…with Solidity agreeing with cast" "$e2e_out" "Solidity agrees with cast"

# The producer stamps a wall-clock `createdAt`, so the raw bytes drift between
# runs while the canonical digest does not. That is the point of the extra pin.
sleep 1
(cd "$PRODUCER" && forge script script/BuildBatch.s.sol:BuildBatch >/dev/null 2>&1)
assert_eq "the canonical digest survives a re-run" \
  "$(bash "$NORMALIZE" --input "$PRODUCER/out/batch.json" --safe "$SAFE" --nonce 7 2>/dev/null | canonical_sha)" \
  "$E2E_SHA"

write_config "$TMP/e2e-bad-hash.toml" "$E2E_SHA" \
  "0x0000000000000000000000000000000000000000000000000000000000000000"
bad_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-bad-hash.toml" 2>&1)
bad_rc=$?
if [[ $bad_rc -ne 0 ]]; then pass "a wrong expected_safe_tx_hash is NOT ATTESTED"
else fail "a wrong expected_safe_tx_hash was accepted"; fi
assert_contains "…and says which check failed" "$bad_out" "NOT ATTESTED"

write_config "$TMP/e2e-bad-sha.toml" "deadbeef" "$E2E_HASH"
sha_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-bad-sha.toml" 2>&1)
sha_rc=$?
if [[ $sha_rc -ne 0 ]]; then pass "a wrong canonical sha256 is NOT ATTESTED"
else fail "a wrong canonical sha256 was accepted"; fi
assert_contains "…naming the canonical digest" "$sha_out" "canonical sha256 mismatch"

# Binding the same batch to a different nonce must change the transaction, and
# therefore break a claim pinned to the old one.
sed 's/^safe_nonce.*/safe_nonce   = "8"/' "$TMP/e2e.toml" >"$TMP/e2e-nonce.toml"
nonce_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nonce.toml" 2>&1)
nonce_rc=$?
if [[ $nonce_rc -ne 0 ]]; then pass "re-binding the batch to another nonce is NOT ATTESTED"
else fail "a nonce change went undetected"; fi

# ------------------------------------------------------------------- verdict

echo
if [[ $FAILED -eq 0 ]]; then
  printf '%s%s%d passed%s\n' "$BOLD" "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%s%d failed%s, %d passed\n' "$BOLD" "$RED" "$FAILED" "$RESET" "$PASS"
  exit 1
fi
