#!/usr/bin/env bash
# Contract: every `claude -p` call-site in loop/bin/ MUST carry --disallowedTools including Bash. The loop's
# LLM workers (reviewer/gardener/miner) run UNTRUSTED input — transcript slices, memory bodies — under
# --permission-mode bypassPermissions, which IGNORES --allowedTools, so a denylist is the ONLY gate against
# arbitrary Bash/exfil (a prompt-injection in a slice or a poisoned memory could otherwise steer a worker into
# a shell command). Fails on any NEW unguarded call-site — guards the CLASS ("bypass + allowlist = no gate"),
# not three specific scripts. Public-safe (greps shipped source; no private data, no model calls).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; rc=0; n=0
for f in "$root"/loop/bin/*.sh; do
  # only a REAL (non-comment) `claude -p` invocation counts
  grep -E 'claude -p' "$f" | grep -vqE '^[[:space:]]*#' || continue
  n=$((n+1))
  if grep -q -- '--disallowedTools' "$f" && grep -- '--disallowedTools' "$f" | grep -qw Bash; then
    echo "  ok    $(basename "$f") — claude -p carries --disallowedTools incl. Bash"
  else
    echo "  FAIL  $(basename "$f") — claude -p has NO --disallowedTools Bash (bypassPermissions ignores --allowedTools → arbitrary Bash on untrusted input)"; rc=1
  fi
done
[ "$n" -ge 3 ] || { echo "  FAIL  expected ≥3 claude -p call-sites (review/garden/mine), found $n — sweep drift?"; rc=1; }
echo "  ($n claude -p call-site(s) checked)"
exit "$rc"
