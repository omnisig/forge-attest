#!/usr/bin/env bash
# common.sh — logging helpers and a tiny flat-TOML reader for forge-attest.

# --- pretty logging (no color when not a tty) ---------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RESET=; C_BOLD=; C_GREEN=; C_RED=; C_YELLOW=; C_DIM=
fi

step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# --- minimal TOML reader ------------------------------------------------------
# Supports flat `key = "value"` / `key = value` lines and ignores comments and
# [section] headers. Values are returned verbatim (quotes stripped). Good enough
# for a small, well-known config; not a general TOML parser.
toml_get() {
  local file="$1" key="$2" rhs val
  rhs=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1) || true
  [[ -n "$rhs" ]] || { echo ""; return 0; }
  rhs=${rhs#*=}
  rhs=$(printf '%s' "$rhs" | sed -E 's/^[[:space:]]+//')   # trim leading space
  if [[ "$rhs" == \"* ]]; then
    # quoted: take everything between the first pair of double quotes
    val=$(printf '%s' "$rhs" | sed -E 's/^"([^"]*)".*/\1/')
  else
    # bare: drop inline comment, trim trailing space
    val=${rhs%%#*}
    val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+$//')
  fi
  printf '%s' "$val"
}

# normalise a hex string to lowercase 0x-prefixed
lc() { printf '%s' "${1,,}"; }
