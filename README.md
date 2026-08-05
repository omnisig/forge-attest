# forge-attest

[![attest](https://github.com/xsafe/forge-attest/actions/workflows/attest.yml/badge.svg)](https://github.com/xsafe/forge-attest/actions/workflows/attest.yml)

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
five layered, independent checks:

| # | Check | Answers | How |
|---|-------|---------|-----|
| 1 | **Source integrity** | Is this the genuine, unmodified output of *that* script version? | Clone the producer at the pinned commit, re-run its Forge script, and assert the emitted JSON's `sha256` equals the pinned value. |
| 2 | **Canonical integrity** | Does it describe the same transaction, whatever the producer's formatting? | Fold the JSON into one canonical `SafeTx` and assert *its* `sha256` matches. Stable across timestamps, key order and hex casing — the pin to use when a producer isn't byte-deterministic. |
| 3 | **Hash derivation (cast)** | Does that map to exactly one Safe tx? | Recompute the EIP-712 `safeTxHash` from the canonical form with `cast`; assert it equals the pinned `expected_safe_tx_hash`. |
| 4 | **Hash cross-check (Solidity)** | Is the derivation itself trustworthy? | A `forge test` re-reads the *producer's* JSON, redoes the folding and recomputes the same hash in Solidity, asserting it agrees with #3 and the pinned value — so no single implementation is trusted, and normalisation itself is covered. |
| 5 | **Live integrity** | Is the tx *actually queued in the Safe* the same one? | Run `safe-tx-hashes-util` against the Safe Transaction Service (`--network --address --nonce`) and assert the queued tx's hash equals the script-derived hash. |

If all active checks pass, the submitted Safe tx is provably the script's output. If
anything was changed — the script, the JSON, or the queued tx — at least one hash
diverges and the run prints **`NOT ATTESTED`** and exits non-zero.

## Usage

```bash
./attest.sh                       # uses ./attest.toml
./attest.sh --config my.toml      # a different claim
./attest.sh --require-live        # fail (don't skip) if the live check can't run
./attest.sh --json                # machine-readable verdict on stdout
./attest.sh --keep                # keep the temp clone for inspection
```

Requirements: `git`, `foundry` (`forge` + `cast`), `jq`, `sha256sum`, `bash`.

Exit code is the verdict: `0` attested, `1` not.

### Machine-readable output

`--json` writes the verdict to stdout and moves the human report to stderr, so a
caller gets both without scraping colours:

```bash
./attest.sh --json 2>/dev/null | jq -r '.hashes.safe_tx'
```

```json
{
  "attested": true,
  "producer": { "repo": "…", "commit": "df1d6f36…", "script": "script/BuildSafeTx.s.sol:BuildSafeTx" },
  "safe": { "address": "0x111CEE…", "nonce": "42", "network": "ethereum", "version": "1.3.0" },
  "toolchain": { "forge": "1.7.1-stable", "forge_commit": "…", "cast": "1.7.1-stable", "producer_solc": "0.8.28" },
  "hashes": {
    "output_sha256": "f8b05de9…",
    "canonical_sha256": "9057b9be…",
    "domain": "0xf10a0411…",
    "message": "0xe6548104…",
    "safe_tx": "0xd0e33f3b…",
    "safe_tx_solidity": "0xd0e33f3b…",
    "safe_tx_live": ""
  },
  "nested": null,
  "failures": []
}
```

A hash that was skipped rather than computed is `""` — an empty `safe_tx_live`
means the live check did not run, not that it passed. `nested` is `null` unless
the claim names a child Safe. `failures` lists exactly what a `NOT ATTESTED`
verdict is based on.

## GitHub Action

The action at the root of this repository runs the same script:

```yaml
- uses: actions/checkout@v4
- uses: xsafe/forge-attest@<commit-sha>
  with:
    config: attest.toml
    require-live: true
```

It installs Foundry, runs `attest.sh --json` against your config, writes the
verdict to the job summary, and exposes `attested`, `safe-tx-hash`,
`canonical-sha256`, `child-safe-tx-hash`, and the full `json` document as step
outputs. Put `attest.toml` in your own ops repo and point `producer_repo` at it.

**Pin the action to a commit SHA, not a tag.** A tag is mutable, and whoever can
move it decides what "verified" means in your pipeline — which is the property
this tool exists to remove. Pinning a SHA fixes the action, `attest.sh`, `lib/`,
and the Solidity cross-check together, because they are all this one repository
at one commit. `foundry-version` matters for the same reason — `forge` re-runs
the producer's script, so a moving toolchain can move the output bytes — which
is why it defaults to a pinned release rather than `stable`. Override it
deliberately, and bump it as a reviewed change.

That argument binds us too, so the action pins its own dependencies by commit
SHA rather than by tag. Otherwise whoever could move a tag we referenced would
get code execution inside the verification step of every pipeline using this
action — the one step whose output everyone downstream is trusting.

## Supported producer formats

`forge-attest` takes whatever Safe JSON your ops repo already emits — the format is
detected automatically (or named explicitly with `input_format`).

### `safe-tx` — a complete transaction

A flat object carrying the full EIP-712 `SafeTx` field set. All scalars are quoted
strings so large integers survive JSON:

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

### `tx-builder` — a Safe{Wallet} Transaction Builder batch

The shape produced by the Safe UI's "export batch" and by FraxFinance's
[`SafeTxHelper.writeTxs`](https://github.com/FraxFinance/frax-standard-solidity/blob/master/src/SafeTxHelper.sol):

```json
{
  "version": "1.0",
  "chainId": 10,
  "createdAt": 1760128999000,
  "meta": { "name": "Transactions Batch", "description": "" },
  "transactions": [
    { "to": "0x…", "value": "0", "data": "0x…", "operation": "0" }
  ]
}
```

### `tx-array` — a bare array

Just the `transactions` list, with no envelope. `chain_id` then has to come from the
config.

### What a batch does *not* tell you

A batch carries no Safe address, no nonce and no gas fields. **It is not yet a
transaction.** It becomes one only when bound to a specific Safe at a specific nonce
and folded into the single call owners actually sign:

- **more than one transaction** → packed into `multiSend(bytes)` and executed as a
  `DELEGATECALL` into `MultiSendCallOnly`, exactly as Safe{Wallet} submits it;
- **exactly one transaction** → sent directly to its target, also matching the UI
  (override with `batch_mode = "multisend"`).

So `safe_address` and `safe_nonce` in `attest.toml` are *inputs to the hash* for
batch formats, not just live-check settings. The same batch on a different Safe, or
at a different nonce, is a different transaction and will not match a pin.

The schema does have a slot for the Safe — `meta.createdFromSafeAddress` — and
`forge-attest` reads it. A producer that fills it in makes the file self-binding, so
`safe_address` becomes an independent cross-check rather than a required input; if
the two disagree, that is a tampering signal and the run fails rather than picking
one. Nothing carries the nonce, so that always comes from the config.

The default `MultiSendCallOnly` is the canonical deployment for the configured
`safe_version` — 1.3.x, 1.4.x and 1.5.x are known; any other version must name
`multisend_address`.

That default is **not** universal across chains. On some chains the canonical
address isn't deployed at all, and on the zkSync-family chains (zkSync Era, Abstract,
…) a different-bytecode deployment is the one Safe{Wallet} actually uses. Rather than
guess, `forge-attest` refuses on those chains and asks for `multisend_address`:

```
normalize.sh: chain 324 does not use the canonical MultiSendCallOnly for Safe 1.3.0;
              pass --multisend explicitly (see lib/multisend-exceptions.json)
```

[`lib/multisend-exceptions.json`](lib/multisend-exceptions.json) is generated from
[`safe-global/safe-deployments`](https://github.com/safe-global/safe-deployments) and
read by *both* derivations, so the two cannot drift. Safe 1.5.0 has no divergent
chains; 1.4.1 has 7; 1.3.0 has 112.

Batches are also where the byte-exact `sha256` stops being usable: `SafeTxHelper`
stamps `createdAt` with `block.timestamp * 1000`, so the file's bytes change on every
run. Leave `expected_output_sha256` blank for such producers and pin
`expected_canonical_sha256` instead — the canonical form has a fixed key order,
quoted scalars and lowercase hex, so timestamps, `meta`, key reordering, address
checksum casing and string-vs-number scalars cannot move it, while anything the Safe
would actually execute does.

You can run the normaliser on its own to see what a given file folds into:

```bash
./lib/normalize.sh --input path/to/batch.json \
  --safe 0x<safe> --nonce <n> --summary
```

### Refused on purpose

- **`contractMethod` with a null `data`.** UI exports can describe a call as an ABI
  method plus input values. Encoding that requires the target ABI; rather than invent
  calldata, `forge-attest` fails and asks for an export with encoded `data`.
- **Inner `operation: 1` under `MultiSendCallOnly`.** That contract reverts on
  delegatecalls, so the batch could never execute. Pass the plain MultiSend via
  `multisend_address` if you really mean it.
- **A config value that contradicts the JSON.** If both carry a `chainId` and they
  disagree, that is a tampering signal — it errors rather than silently picking one.

## Nested Safes

When a Safe is owned by other Safes, a child cannot sign — it approves on-chain by
calling `parent.approveHash(h)`, where `h` is the parent's transaction hash. That
approval is a Safe transaction in its own right, and it is the one the child's owners
actually sign. They never sign the parent transaction.

They also cannot see it. `approveHash` stores a flag against `(owner, hash)` and never
learns the preimage; at execution the full transaction is supplied again and re-hashed.
So no on-chain state can tell a signer what `0xd4d9bdcd6dadc73a…` means — the preimage
exists only in the producer's artifact. That is the gap this closes.

Add to any claim:

```toml
child_safe    = "0x<the child Safe>"
child_nonce   = "7"
child_network = ""     # set to also check what is queued on the child itself
expected_child_safe_tx_hash = ""
```

There is no artifact for the approval and no producer script writes one. Given the
parent Safe, the parent hash, the child Safe and the child's nonce, every field is
determined, so `forge-attest` constructs it — in bash and in Solidity independently,
and compares them as it does every other hash:

```
==> Nested approval (child Safe)
    child    : 0x2222AA…22FF nonce 7
    approves : 0x7f9d67d2…c115
    signs    : 0x6ca5575d…b660
  ✓ Solidity agrees with cast on the approval

 ATTESTED  …
     sign 0x6ca5575d…b660 on 0x2222AA…22FF
    valid only while 0x111CEEee…2177 nonce == 43
```

That last line is the part to read carefully. The parent hash binds the parent's
nonce, so if the parent executes anything else first, every stored approval silently
stops matching and execution fails as `GS025` — "invalid owner" — with nothing in the
error pointing at the real cause.

**Out of scope.** Whether enough children approved (`approveHash` reverts with `GS030`
unless the caller is already an owner, so a mis-aimed approval cannot silently count —
but the tool does not tally against the threshold); nesting more than one level deep;
EIP-1271 contract signatures, which produce a signature blob rather than a reviewable
transaction; and several different transactions queued at the same nonce.

## Pointing it at your own repo

Edit `attest.toml`:

```toml
producer_repo   = "https://github.com/you/your-ops-repo"
producer_commit = "<40-hex commit sha>"
producer_script = "script/YourScript.s.sol:YourScript"
output_path     = "out/safe-tx.json"

expected_output_sha256    = "<sha256 of that JSON>"     # blank if not byte-stable
expected_canonical_sha256 = "<sha256 of the canonical form>"
expected_safe_tx_hash     = "0x<safeTxHash>"

safe_network = "ethereum"
safe_address = "0x<your safe>"
safe_nonce   = "<nonce>"
```

To get the pinned values the first time, run once with them blank — the orchestrator
prints every hash it computes, which you then paste back in as the expectation *after
reviewing the transaction*. See
[`attest.batch.example.toml`](attest.batch.example.toml) for a fully commented batch
claim.

## Threat model

**Catches**
- The Forge script was changed (any commit other than the pinned one → different
  output → sha256 + hash mismatch).
- The JSON was hand-edited after the script ran (`to`, `value`, `data`, `nonce`, …)
  → derived hash diverges.
- A batch was edited: a transaction added, removed, reordered, redirected, or its
  calldata altered → the `multiSend` payload and therefore the signed hash change.
- The batch was re-bound to a different Safe, nonce or chain → different hash.
- The tx queued in the Safe differs from the script output → live hash mismatch
  (check #5).
- A nested approval pointing at a different transaction than the one under review —
  the approval is re-derived from the parent, never read back from it.

**Does not catch (out of scope)**
- Whether the script's *intent* is correct — `forge-attest` proves provenance, not
  that the transaction does what you want. Review the script.
- A malicious producer commit that you then pin — you are attesting to a specific
  commit; pin one you have reviewed.
- Safe contract versions `< 1.3.0` in the offline deriver (checks #3/#4). The live
  check (#5) still handles them via `safe-tx-hashes-util`.
- Batch entries expressed as `contractMethod` + inputs with no encoded calldata —
  refused rather than guessed at.
- Whether a nested approval will still be valid when it executes. The parent's nonce
  can move at any time, and only the live check can notice.

## Tests

The verifier has its own test suite; nothing it attests is worth much if its two hash
derivations don't agree.

```bash
forge test            # Solidity: hashing, MultiSend packing, every JSON format
./test/shell/run.sh   # bash: normalisation, cast-vs-Solidity, full end-to-end runs
```

`test/fixtures/` holds one file per supported shape, including a real
`SafeTxHelper`-generated batch from FraxFinance's `frax-oft-upgradeable` — see
[`test/fixtures/README.md`](test/fixtures/README.md). Both suites derive hashes from
the same fixtures independently and assert the same pinned values, so a divergence
between the bash and Solidity implementations fails the build.

## CI

[`.github/workflows/attest.yml`](.github/workflows/attest.yml) runs the tests and then
the full attestation pipeline on every push/PR and nightly. A green CI run is a
public, timestamped attestation that a third party can rely on without re-running
anything. (In CI, set `producer_repo` to a reachable git URL rather than a `file://`
path.) It runs through `uses: ./`, so the action published from this repo is
exercised on every push rather than only in consumers' pipelines.

## Layout

```
forge-attest/
├── attest.sh                     # orchestrator
├── action.yml                    # GitHub Action wrapping attest.sh
├── attest.toml                   # the claim being attested
├── attest.batch.example.toml     # a commented claim for a Transaction Builder batch
├── lib/
│   ├── normalize.sh              # any supported JSON -> canonical SafeTx (check #2)
│   ├── nested.sh                 # constructs a child Safe's approveHash tx
│   ├── derive.sh                 # cast-based safeTxHash derivation (check #3)
│   ├── safe_hashes.sh            # vendored safe-tx-hashes-util (check #5)
│   ├── common.sh                 # logging + tiny TOML reader
│   └── VENDORED.md               # provenance of the vendored tool
├── test/
│   ├── SafeTx.sol                # Solidity SafeTx model + MultiSend + JSON readers
│   ├── SafeTxHash.t.sol          # standalone unit tests over the fixtures
│   ├── Attest.t.sol              # Solidity cross-check driven by attest.sh (check #4)
│   ├── fixtures/                 # one JSON per supported shape
│   └── shell/run.sh              # bash test suite
├── foundry.toml
└── .github/workflows/attest.yml  # continuous attestation
```

## Trust anchor

`forge-attest` never asks you to trust *it*. Every hash is derived three ways (cast,
Solidity, and — live — `safe-tx-hashes-util`) from inputs you pin, and the two offline
implementations fold batches independently rather than sharing code. Don't trust,
verify.
