# Test fixtures

Every JSON shape `forge-attest` accepts, pinned as a file so the hash derivations
have something stable to be tested against. `test/SafeTxHash.t.sol` reads these
from Solidity and `test/shell/run.sh` from bash; both assert the same hashes.

| File | Format | What it covers |
|------|--------|----------------|
| `safe-tx-single.json` | `safe-tx` | A flat, complete EIP-712 SafeTx — the output of [`forge-attest-example-safe-ops`](https://github.com/omnisig/forge-attest-example-safe-ops) at commit `df1d6f36`. |
| `tx-builder-frax-optimism.json` | `tx-builder` | A real six-transaction batch (see provenance below). The main worked example. |
| `tx-builder-frax-optimism-restamped.json` | `tx-builder` | The *same* batch with a different `createdAt` and `meta`, reordered keys, lowercased addresses, uppercased hex, and numbers where the original had quoted strings. Must normalise to identical bytes. |
| `tx-builder-single.json` | `tx-builder` | A one-transaction batch with `"data": null` — a plain ETH transfer. Exercises the "don't wrap a single transaction" path. |
| `tx-array.json` | `tx-array` | A bare array with no envelope, so `chainId` has to come from config. |
| `tx-builder-contract-method.json` | `tx-builder` | A UI export describing a call as `contractMethod` + inputs with null `data`. Must be **rejected** — encoding it needs the target ABI. |
| `tx-builder-delegatecall.json` | `tx-builder` | A batch with an inner `operation: 1`. Must be **rejected** under MultiSendCallOnly and accepted with an explicit `--multisend`. |

## Provenance of `tx-builder-frax-optimism.json`

Copied verbatim from FraxFinance's `frax-oft-upgradeable`:

- **File:** `scripts/ops/V110/destinations/txs/UpgradeV110Destination-10.json`
- **Repo:** https://github.com/FraxFinance/frax-oft-upgradeable
- **Produced by:** [`SafeTxHelper.writeTxs`](https://github.com/FraxFinance/frax-standard-solidity/blob/master/src/SafeTxHelper.sol)
  in `frax-standard-solidity`
- **Fetched:** 2026-07-28

It is six `upgradeAndCall` calls to a proxy admin on Optimism (chain 10), and is
the reference for what a real `SafeTxHelper` artifact looks like: a `createdAt`
wall-clock stamp, `meta`, `value`/`operation` as quoted strings, and no Safe
address, nonce or gas fields anywhere — those are exactly the facts an attestation
config has to supply.
