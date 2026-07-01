#!/usr/bin/env bash
# Stop hook: fires once per assistant turn. If enough has happened since the last
# review, claims the slice and spawns a detached reviewer. ALWAYS exits 0 (never blocks).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0

input="$(cat 2>/dev/null)"                              # always drain stdin first

[ "${CLAUDE_CODE_CHILD_SESSION:-0}" = "1" ] && exit 0   # never recurse into reviewer sessions
[ -n "${LOOP_REVIEWER:-}" ] && exit 0
[ "${LOOP_ENABLED:-0}" = "1" ] || exit 0

# Self-heal: a turn just completed → you're active at the machine. Recover a missed/failed gardener
# OR a crashed miner run now, rather than waiting for the next nightly pass (you leave sessions open,
# so SessionStart won't re-fire). Spawns ONE ordered detached worker only when something's due —
# cooldown-gated (≤1/2h each), a near-instant no-op on almost every turn.
maybe_selfheal_async

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

turn_hit=0; tool_hit=0
[ "${REVIEW_EVERY_TURNS:-0}" -gt 0 ] && [ "${n_turns:-0}" -ge "$REVIEW_EVERY_TURNS" ] && turn_hit=1
[ "${REVIEW_EVERY_TOOLCALLS:-0}" -gt 0 ] && [ "${n_tools:-0}" -ge "$REVIEW_EVERY_TOOLCALLS" ] && tool_hit=1
if [ "$turn_hit" = 1 ] || [ "$tool_hit" = 1 ]; then
  log "stop: trigger session=$session turns=$n_turns tools=$n_tools (lines $((last + 1))-$cur)"
  # watermark advances inside review.sh only on success (failed/API-errored reviews retry); lock prevents double-spawn.
  nohup bash "$LOOP_DIR/bin/review.sh" "$slice" "$session" "$cwd" "$cur" >> "$LOG" 2>&1 < /dev/null & disown
else
  rm -f "$slice"
fi
exit 0
