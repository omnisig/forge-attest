#!/usr/bin/env bash
#
# nested.sh — build the Safe transaction a *child* Safe sends to approve a
#             transaction on a parent Safe it owns.
#
# A Safe cannot produce an ECDSA signature, so when a Safe owns another Safe it
# approves on-chain instead: it calls `parent.approveHash(h)`, where `h` is the
# parent's EIP-712 transaction hash. That approval is itself a Safe transaction,
# and it is the one the child's owners actually sign.
#
# Nothing about it is a matter of choice. Given the parent Safe, the parent's
# hash, the child Safe and the child's nonce, every field is determined:
#
#     to        = <parent safe>
#     value     = 0
#     data      = 0xd4d9bdcd ‖ <parent hash>      (36 bytes)
#     operation = 0
#     gas fields = 0
#     nonce     = <child nonce>
#
# So this script *constructs* the transaction rather than verifying a file. There
# is no producer artifact for an approval, and inventing one would only add
# something else to tamper with. The output is a canonical SafeTx, so
# `derive.sh` hashes it exactly like any other.
#
# Note what the parent hash does NOT tell the Safe: nothing. `approveHash` stores
# a flag against (owner, hash) and never learns the preimage. At execution the
# full transaction is supplied again and re-hashed. That is why the parent's
# decoded intent has to travel with this — on-chain state can never explain to a
# signer what they approved.
#
# Usage:
#   nested.sh --parent-safe 0x… --parent-hash 0x… \
#             --child-safe 0x… --child-nonce N --chain-id N [--safe-version V]
set -euo pipefail

PARENT_SAFE=""; PARENT_HASH=""; CHILD_SAFE=""; CHILD_NONCE=""
CHAIN_ID=""; SAFE_VERSION="1.3.0"

APPROVE_HASH_SELECTOR="d4d9bdcd"

die() { printf 'nested.sh: %s\n' "$*" >&2; exit 1; }
lower() { printf '%s' "${1,,}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent-safe)  PARENT_SAFE="$2"; shift 2 ;;
    --parent-hash)  PARENT_HASH="$2"; shift 2 ;;
    --child-safe)   CHILD_SAFE="$2"; shift 2 ;;
    --child-nonce)  CHILD_NONCE="$2"; shift 2 ;;
    --chain-id)     CHAIN_ID="$2"; shift 2 ;;
    --safe-version) SAFE_VERSION="$2"; shift 2 ;;
    -h|--help)      grep -E '^#' "$0" | sed -E 's/^#\??//' | sed -E 's/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

parent_safe=$(lower "$PARENT_SAFE")
child_safe=$(lower "$CHILD_SAFE")
parent_hash=$(lower "$PARENT_HASH")

[[ "$parent_safe" =~ ^0x[0-9a-f]{40}$ ]] || die "--parent-safe must be a 20-byte address"
[[ "$child_safe"  =~ ^0x[0-9a-f]{40}$ ]] || die "--child-safe must be a 20-byte address"
[[ "$parent_hash" =~ ^0x[0-9a-f]{64}$ ]] || die "--parent-hash must be a 32-byte hash"
[[ "$CHILD_NONCE" =~ ^[0-9]+$ ]]         || die "--child-nonce must be a non-negative integer"
[[ "$CHAIN_ID"    =~ ^[0-9]+$ ]]         || die "--chain-id must be a non-negative integer"

# A Safe cannot own itself, and `approveHash` would be meaningless if it could.
[[ "$parent_safe" != "$child_safe" ]] || die "--child-safe and --parent-safe are the same Safe"

jq -n \
  --arg safe "$child_safe" \
  --arg chainId "$CHAIN_ID" \
  --arg safeVersion "$SAFE_VERSION" \
  --arg to "$parent_safe" \
  --arg data "0x${APPROVE_HASH_SELECTOR}${parent_hash#0x}" \
  --arg nonce "$CHILD_NONCE" \
  '{safe:$safe, chainId:$chainId, safeVersion:$safeVersion, to:$to, value:"0",
    data:$data, operation:"0", safeTxGas:"0", baseGas:"0", gasPrice:"0",
    gasToken:"0x0000000000000000000000000000000000000000",
    refundReceiver:"0x0000000000000000000000000000000000000000", nonce:$nonce}'
