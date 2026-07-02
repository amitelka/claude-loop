#!/usr/bin/env bash
# UserPromptSubmit shadow retriever (measurement window B): score the prompt against the memory index
# and log what a retriever WOULD inject (top-k + verdict, incl. misses) to measure/shadow.jsonl. Injects
# NOTHING — purely passive. Gated + loop-session-filtered. UserPromptSubmit has a 30s budget, so keep it
# fast; log + exit 0 with no stdout (stdout on UserPromptSubmit would be added to Claude's context).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
measure_on || exit 0
input="$(cat 2>/dev/null)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0
line="$(MEM_INDEX="$MEMORY_DIR/MEMORY.md" MV="$MEASUREMENT_VERSION" \
        SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)" \
        PID="$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null)" \
        /usr/bin/python3 "$LOOP_DIR/bin/shadow_score.py" <<<"$prompt" 2>/dev/null)"
[ -n "$line" ] && measure_append shadow "$line"
exit 0
