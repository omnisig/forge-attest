# Vendored third-party code

## `safe_hashes.sh`

- **Source:** https://github.com/pcaversaccio/safe-tx-hashes-util
- **File:** `safe_hashes.sh`
- **Pinned commit:** `e3be687a24af013d455b99d1fcacc5c252e2f1e8`
- **sha256:** `15705ee9a702835b070f5a8cb3bb3c494c0ff091a775fc53f2dbe50c3af62759`
- **Fetched:** 2026-07-27
- **Licence:** AGPL-3.0-only — [`LICENSE-AGPL-3.0.txt`](LICENSE-AGPL-3.0.txt)

The rest of this repository is MIT. The MIT grant does **not** extend to this
file: it is redistributed verbatim under AGPL-3.0-only with its author and
`@license` header intact, and `attest.sh` invokes it as a separate process
rather than incorporating it. Keep the header and this record intact when
updating it.

This is the canonical "Don't trust, verify!" Safe transaction hash calculator. We
vendor it (rather than `curl | bash`) so the exact bytes are pinned and auditable,
and so the live comparison against the Safe Transaction Service uses a known version.

To update: replace the file, bump the commit hash and sha256 above, and re-run
`./attest.sh` to confirm the derived hashes still agree.

## `multisend-exceptions.json`

- **Derived from:** https://github.com/safe-global/safe-deployments
- **sha256:** `397c571bb88f5efc76b8cbdc0fddff461a4337bf7402f0455cb0c87a0c8a8966`

Not third-party code, but load-bearing data: it decides which MultiSend address
is canonical for a given chain and Safe version, and that address is an input to
the transaction hash. A wrong entry here produces a confidently wrong answer.

## Why the checksums

Committing these files already pins them for anyone consuming forge-attest at a
commit — the checksums are maintainer-side. They exist so that a change to a
file that feeds the hash derivation cannot land as an unreviewed diff or a bad
merge without `test/shell/run.sh` objecting. Update them deliberately, in the
same commit as the file.
