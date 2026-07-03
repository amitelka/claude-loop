#!/usr/bin/env bash
# PreCompact: clear this session's injection-dedup file so pointers the compact drops from context can re-inject
# (gap-finding #1 — otherwise a long session, post-compact, still thinks it already injected and silently loses
# those memories). Fail-open, fast. Wired to the PreCompact hook.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
loop_enabled || exit 0   # kill switch: LOOP_ENABLED=0 → fully inert (zero writes, zero stdout)
input="$(cat 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] && rm -f "$STATE_DIR/inject/$(sanitize_sid "$sid").txt" 2>/dev/null   # sid is hook input — sanitize before path use
exit 0
