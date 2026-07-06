#!/usr/bin/env bash
# Passive-measurement gate (measure_on): record only when MEASUREMENT_ENABLED and LOOP_ENABLED, and
# NEVER in the loop's own claude -p sessions (CLAUDE_CODE_CHILD_SESSION / LOOP_REVIEWER) — else the
# gardener/reviewer/miner reading every memory would swamp read-counts (the loop talking to itself).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state"
# shellcheck source=/dev/null
. "$root/loop/lib.sh" 2>/dev/null || { echo "  FAIL  cannot source lib.sh"; exit 1; }
rc=0
ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
gate() { ( export MEASUREMENT_ENABLED="$1" LOOP_ENABLED="$2" CLAUDE_CODE_CHILD_SESSION="$3" LOOP_REVIEWER="$4"; measure_on && echo on || echo off ); }

ok "$(gate 1 1 0 '')" on  "enabled + top-level session → on"
ok "$(gate 0 1 0 '')" off "MEASUREMENT_ENABLED=0 → off"
ok "$(gate 1 0 0 '')" off "LOOP_ENABLED=0 → off"
ok "$(gate 1 1 1 '')" on  "CHILD=1 alone → on (this env sets it on normal sessions; CHILD must NOT filter)"
ok "$(gate 1 1 0 x)"  off "LOOP_REVIEWER=1 → off (the real loop-internal opt-out)"

( export MEASURE_DIR="$tmp/m"; measure_append reads '{"v":1,"path":"a.md"}' )
ok "$([ -f "$tmp/m/reads.jsonl" ] && cat "$tmp/m/reads.jsonl")" '{"v":1,"path":"a.md"}' "measure_append → reads.jsonl"

exit "$rc"
