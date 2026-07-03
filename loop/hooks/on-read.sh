#!/usr/bin/env bash
# PostToolUse(Read) telemetry (measurement window B): record reads of memory-global files — main-agent
# AND subagent (keyed by agent_id, present only for subagent calls). Passive, gated, loop-session-
# filtered. Fast path-prefix bail on non-memory reads so it doesn't tax every Read. Never blocks; exit 0.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
loop_enabled || exit 0   # kill switch: LOOP_ENABLED=0 → fully inert (measure_on also gates it; explicit + uniform)
measure_on || exit 0
input="$(cat 2>/dev/null)"
printf '%s' "$input" | grep -qF "$MEMORY_DIR" || exit 0          # fast bail: non-memory read, skip the jq
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
case "$path" in "$MEMORY_DIR"/*) ;; *) exit 0 ;; esac            # only reads under memory-global
rel="${path#"$MEMORY_DIR"/}"
line="$(printf '%s' "$input" | jq -c \
  --argjson v "$MEASUREMENT_VERSION" --argjson ts "$(date +%s)" --arg rel "$rel" \
  '{v:$v, ts:$ts, stream:"read", session:(.session_id//null), prompt:(.prompt_id//null), agent:(.agent_id//null), path:$rel}' 2>/dev/null)"
[ -n "$line" ] && measure_append reads "$line"
exit 0
