#!/usr/bin/env bash
# Nightly backstop: review sessions with un-reviewed activity (caught below the
# per-turn threshold, or that ended). Shares the watermark with the Stop hook.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1

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
    bash "$LOOP_DIR/bin/review.sh" "$slice" "$session" "${cwd:-$PWD}" "$cur"
  else
    rm -f "$slice"
  fi
done
log "harvest: nightly pass complete"
