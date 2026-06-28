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

# Garden catch-up (self-heal, mirrors the reviewer): if the gardener hasn't confirmed success in
# >24h, run it now — we're awake and just exercised the API on the reviews above. Cooldown: at most
# once / 6h so repeated manual harvests don't spawn back-to-back gardens.
now="$(date +%s)"
gok="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
gtry="$(cat "$STATE_DIR/garden.catchup" 2>/dev/null || echo 0)"
if [ "$((now - gok))" -gt 86400 ] && [ "$((now - gtry))" -gt 21600 ]; then
  echo "$now" > "$STATE_DIR/garden.catchup"
  log "harvest: garden stale (last ok $(date -r "$gok" '+%F %H:%M' 2>/dev/null || echo never)) — running catch-up"
  bash "$LOOP_DIR/bin/garden.sh" --catch-up
fi
log "harvest: nightly pass complete"
