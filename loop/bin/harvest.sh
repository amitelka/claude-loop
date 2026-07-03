#!/usr/bin/env bash
# Nightly backstop: review sessions with un-reviewed activity (caught below the
# per-turn threshold, or that ended). Shares the watermark with the Stop hook.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
guard_loop_enabled harvest   # kill switch: autonomous entry point no-ops when LOOP_ENABLED=0

proj_root="$CLAUDE_HOME/projects"
find "$proj_root" -name '*.jsonl' -type f -mtime -2 -not -path '*/subagents/*' -not -path '*/workflows/*' 2>/dev/null | while read -r t; do
  session="$(basename "$t" .jsonl)"
  cur="$(wc -l < "$t" | tr -d ' ')"
  wm="$STATE_DIR/$session.line"
  last="$(cat "$wm" 2>/dev/null || echo 0)"
  [ "$cur" -gt "$last" ] || continue

  slice="$(mktemp -t loop-slice.XXXXXX)"
  tail -n +"$((last + 1))" "$t" > "$slice"
  n_turns="$(count_turns < "$slice")"
  n_tools="$(count_tools < "$slice")"
  if [ "${n_turns:-0}" -ge 2 ] || [ "${n_tools:-0}" -ge 3 ]; then
    cwd="$(jq -r 'select(.cwd) | .cwd' "$t" 2>/dev/null | tail -1)"
    log "harvest: session=$session turns=$n_turns tools=$n_tools"
    bash "$LOOP_DIR/bin/review.sh" "$slice" "$session" "${cwd:-$PWD}" "$cur" "harvest"
  else
    rm -f "$slice"
  fi
done

# Self-heal (same-day recovery): re-run a missed/failed gardener, then retry a crashed miner. Both
# also fire from the Stop hook the moment you're active (sessions stay open, so SessionStart rarely
# re-fires); the shared maybe_*_catchup live in lib.sh. Garden before miner so they don't race the lock.
maybe_garden_catchup
maybe_miner_catchup
log "harvest: nightly pass complete"
