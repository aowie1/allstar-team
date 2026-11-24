#!/usr/bin/env bash
# Fail if an agent's copy of a shared output block differs from docs/output-formats.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
spec="$root/docs/output-formats.md"

block() { # block <name> <file>: print lines between the markers, exclusive
  awk -v s="<!-- $1:start -->" -v e="<!-- $1:end -->" \
    '$0==s{on=1;next} $0==e{on=0} on' "$2"
}

fail=0
check() { # check <name> <file>...
  local name="$1"; shift
  local want; want="$(block "$name" "$spec")"
  [ -n "$want" ] || { echo "FAIL canonical $name block missing in $spec"; fail=1; return; }
  local f
  for f in "$@"; do
    if [ "$(block "$name" "$f")" != "$want" ]; then
      echo "FAIL $name differs or is missing: ${f#"$root"/}"
      fail=1
    fi
  done
}

check output-contract "$root"/agents/*.md
check review-template \
  "$root/agents/code-reviewer.md" \
  "$root/agents/alignment-reviewer.md" \
  "$root/agents/security-specialist.md" \
  "$root/agents/review-dispatcher.md"

[ "$fail" -eq 0 ] && echo "ok: output blocks match docs/output-formats.md"
exit "$fail"
