# forge-attest

[![attest](https://github.com/omnisig/forge-attest/actions/workflows/attest.yml/badge.svg)](https://github.com/omnisig/forge-attest/actions/workflows/attest.yml)

**Prove that a Gnosis Safe transaction is exactly the output of a specific Forge
script — and was not manipulated on its way to the Safe.**

When an ops/treasury team builds a Safe transaction with a Forge script in one repo
and then submits the resulting JSON to a Safe for signers to approve, a gap opens up:
*how does a signer know the thing in the Safe queue is really what the script
produced, and not something edited in between?* `forge-attest` closes that gap by
re-deriving everything from a pinned commit and comparing hashes, using
[`safe-tx-hashes-util`](https://github.com/pcaversaccio/safe-tx-hashes-util) for the
live comparison.

```
 ATTESTED  the submitted Safe tx is exactly the output of script/BuildSafeTx.s.sol:BuildSafeTx@df1d6f369294
```

## How it proves it

Given a claim in [`attest.toml`](attest.toml) — a producer repo, a pinned commit, the
script it runs, and the exact outputs that commit must produce — `./attest.sh` runs
four layered, independent checks:

| # | Check | Answers | How |
|---|-------|---------|-----|
| 1 | **Source integrity** | Is this the genuine, unmodified output of *that* script version? | Clone the producer at the pinned commit, re-run its Forge script, and assert the emitted JSON's `sha256` equals the pinned value. Determinism makes this byte-exact. |
| 2 | **Hash derivation (cast)** | Does that JSON map to exactly one Safe tx? | Recompute the EIP-712 `safeTxHash` from the JSON with `cast`; assert it equals the pinned `expected_safe_tx_hash`. |
| 3 | **Hash cross-check (Solidity)** | Is the derivation itself trustworthy? | A `forge test` recomputes the same hash in Solidity (canonical Safe primitives) and asserts it agrees with #2 and the pinned value — so no single implementation is trusted. |
| 4 | **Live integrity** | Is the tx *actually queued in the Safe* the same one? | Run `safe-tx-hashes-util` against the Safe Transaction Service (`--network --address --nonce`) and assert the queued tx's hash equals the script-derived hash. |

If all active checks pass, the submitted Safe tx is provably byte-for-byte the
script's output. If anything was changed — the script, the JSON, or the queued tx —
at least one hash diverges and the run prints **`NOT ATTESTED`** and exits non-zero.

## Usage

```bash
./attest.sh                       # uses ./attest.toml
./attest.sh --config my.toml      # a different claim
./attest.sh --require-live        # fail (don't skip) if the live check can't run
./attest.sh --keep                # keep the temp clone for inspection
```

Requirements: `git`, `foundry` (`forge` + `cast`), `jq`, `sha256sum`, `bash`.

### Pointing it at your own repo

Edit `attest.toml`:

```toml
producer_repo   = "https://github.com/you/your-ops-repo"
producer_commit = "<40-hex commit sha>"
producer_script = "script/YourScript.s.sol:YourScript"
output_path     = "out/safe-tx.json"          # JSON your script writes (see schema below)

expected_output_sha256 = "<sha256 of that JSON>"
expected_safe_tx_hash  = "0x<safeTxHash>"

safe_network = "ethereum"
safe_address = "0x<your safe>"
safe_nonce   = "<nonce>"
```

To get the two pinned values the first time, run once with them blank (or copy them
from a green run) — the orchestrator prints both the `sha256` and the derived
`safeTx` hash, which you then paste back in as the pinned expectation.

### Producer JSON schema

The producer script must emit the full set of EIP-712 `SafeTx` fields. All scalars
are quoted strings so large integers survive JSON:

```json
{
  "safe": "0x…", "chainId": "1", "safeVersion": "1.3.0",
  "to": "0x…", "value": "0", "data": "0x…", "operation": "0",
  "safeTxGas": "0", "baseGas": "0", "gasPrice": "0",
  "gasToken": "0x0000000000000000000000000000000000000000",
  "refundReceiver": "0x0000000000000000000000000000000000000000",
  "nonce": "42"
}
```

See [`../forge-attest-example-safe-ops`](../forge-attest-example-safe-ops) for a
reference producer whose output is byte-stable across machines and compilers.

## Threat model

**Catches**
- The Forge script was changed (any commit other than the pinned one → different
  output → sha256 + hash mismatch).
- The JSON was hand-edited after the script ran (`to`, `value`, `data`, `nonce`, …)
  → derived hash diverges.
- The tx queued in the Safe differs from the script output → live hash mismatch
  (check #4).

**Does not catch (out of scope)**
- Whether the script's *intent* is correct — `forge-attest` proves provenance, not
  that the transaction does what you want. Review the script.
- A malicious producer commit that you then pin — you are attesting to a specific
  commit; pin one you have reviewed.
- Safe contract versions `< 1.3.0` in the offline deriver (checks #2/#3). The live
  check (#4) still handles them via `safe-tx-hashes-util`.

## CI

[`.github/workflows/attest.yml`](.github/workflows/attest.yml) runs the full pipeline
on every push/PR and nightly. A green CI run is a public, timestamped attestation
that a third party can rely on without re-running anything. (In CI, set
`producer_repo` to a reachable git URL rather than a `file://` path.)

## Layout

```
forge-attest/
├── attest.sh                     # orchestrator
├── attest.toml                   # the claim being attested
├── lib/
│   ├── derive.sh                 # cast-based safeTxHash derivation (check #2)
│   ├── safe_hashes.sh            # vendored safe-tx-hashes-util (check #4)
│   ├── common.sh                 # logging + tiny TOML reader
│   └── VENDORED.md               # provenance of the vendored tool
├── test/Attest.t.sol             # Solidity cross-check (check #3)
├── foundry.toml
└── .github/workflows/attest.yml  # continuous attestation
```

## Trust anchor

`forge-attest` never asks you to trust *it*. Every hash is derived three ways (cast,
Solidity, and — live — `safe-tx-hashes-util`) from inputs you pin. Don't trust,
verify.
