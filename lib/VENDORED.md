# Vendored third-party code

## `safe_hashes.sh`

- **Source:** https://github.com/pcaversaccio/safe-tx-hashes-util
- **File:** `safe_hashes.sh`
- **Pinned commit:** `e3be687a24af013d455b99d1fcacc5c252e2f1e8`
- **Fetched:** 2026-07-27

This is the canonical "Don't trust, verify!" Safe transaction hash calculator. We
vendor it (rather than `curl | bash`) so the exact bytes are pinned and auditable,
and so the live comparison against the Safe Transaction Service uses a known version.

To update: replace the file, bump the commit hash above, and re-run `./attest.sh`
to confirm the derived hashes still agree.
