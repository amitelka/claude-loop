#!/usr/bin/env bash
# SessionEnd hook: at session close (the natural task boundary), review the
# un-reviewed tail of this session. Detached so it never delays exit. Always exit 0.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0

input="$(cat 2>/dev/null)"

[ -n "${LOOP_REVIEWER:-}" ] && exit 0   # loop-internal claude -p opt-out (NOT CLAUDE_CODE_CHILD_SESSION — set on normal sessions here; see on-stop.sh)
[ "${LOOP_ENABLED:-0}" = "1" ] || exit 0

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -f "$transcript" ] && [ -n "$session" ] || exit 0

cur="$(wc -l < "$transcript" | tr -d ' ')"
wm="$STATE_DIR/$session.line"
last="$(cat "$wm" 2>/dev/null || echo 0)"
[ "$cur" -gt "$last" ] || exit 0

slice="$(mktemp -t loop-slice.XXXXXX)" || exit 0
tail -n +"$((last + 1))" "$transcript" > "$slice" 2>/dev/null
n_turns="$(count_turns < "$slice")"
n_tools="$(count_tools < "$slice")"
if [ "${n_turns:-0}" -ge 2 ] || [ "${n_tools:-0}" -ge 2 ]; then
  log "session-end: review session=$session turns=$n_turns tools=$n_tools end=$(printf '%s' "$input" | jq -r '.end_reason // "?"' 2>/dev/null)"
  nohup bash "$LOOP_DIR/bin/review.sh" "$slice" "$session" "$cwd" "$cur" "session-end" >> "$LOG" 2>&1 < /dev/null & disown
else
  rm -f "$slice"
fi
exit 0
