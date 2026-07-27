#!/usr/bin/env bash
#
# derive.sh — recompute the Gnosis Safe EIP-712 transaction hash from a JSON file
#             of SafeTx fields, using `cast`. This is one of forge-attest's two
#             independent hash derivations (the other is Solidity, in test/).
#
# Usage:  derive.sh <safe-tx.json>
# Output: three KEY=VALUE lines matching safe-tx-hashes-util's terminology:
#           DOMAIN_HASH=0x...     (EIP-712 domain separator)
#           MESSAGE_HASH=0x...    (hashStruct of the SafeTx)
#           SAFE_TX_HASH=0x...    (final 0x19 0x01 digest = what owners sign)
#
# Only Safe >= 1.3.0 domains are derived here (chainId in the domain, `baseGas`
# field name). For older Safes, rely on the vendored safe_hashes.sh instead.
set -euo pipefail

json="${1:?usage: derive.sh <safe-tx.json>}"
[[ -f "$json" ]] || { echo "derive.sh: no such file: $json" >&2; exit 1; }

get() { jq -er "$1" "$json"; }

safe=$(get '.safe')
chainId=$(get '.chainId')
version=$(get '.safeVersion // "1.3.0"')
to=$(get '.to')
value=$(get '.value')
data=$(get '.data')
operation=$(get '.operation')
safeTxGas=$(get '.safeTxGas')
baseGas=$(get '.baseGas')
gasPrice=$(get '.gasPrice')
gasToken=$(get '.gasToken')
refundReceiver=$(get '.refundReceiver')
nonce=$(get '.nonce')

# Guard: this deriver only implements the modern (>= 1.3.0) domain layout.
major=${version%%.*}; rest=${version#*.}; minor=${rest%%.*}
if (( major == 0 )) || { (( major == 1 )) && (( minor < 3 )); }; then
  echo "derive.sh: Safe version $version < 1.3.0 is not supported by this deriver;" >&2
  echo "           use the vendored safe_hashes.sh for legacy domains." >&2
  exit 2
fi

DOMAIN_TYPEHASH=$(cast keccak "EIP712Domain(uint256 chainId,address verifyingContract)")
SAFE_TX_TYPEHASH=$(cast keccak "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")

domain_hash=$(cast keccak "$(cast abi-encode 'f(bytes32,uint256,address)' \
  "$DOMAIN_TYPEHASH" "$chainId" "$safe")")

data_hash=$(cast keccak "$data")
message_hash=$(cast keccak "$(cast abi-encode \
  'f(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)' \
  "$SAFE_TX_TYPEHASH" "$to" "$value" "$data_hash" "$operation" \
  "$safeTxGas" "$baseGas" "$gasPrice" "$gasToken" "$refundReceiver" "$nonce")")

safe_tx_hash=$(cast keccak "0x1901${domain_hash#0x}${message_hash#0x}")

echo "DOMAIN_HASH=$domain_hash"
echo "MESSAGE_HASH=$message_hash"
echo "SAFE_TX_HASH=$safe_tx_hash"
