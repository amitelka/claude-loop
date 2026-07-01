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

# Garden catch-up (self-heal): re-run the gardener if EITHER it's STALE (no confirmed success in >24h —
# e.g. missed while the laptop slept past 3am) OR the last run FAILED (garden.fail present — e.g. a
# transient API error). The garden's own daily agent only retries NEXT day; the fail-trigger here gives
# SAME-day recovery on the next wake/harvest. Cooldown (reused garden.catchup marker): at most once / 2h,
# so a persistent outage doesn't spawn back-to-back gardens.
now="$(date +%s)"
gok="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
gtry="$(cat "$STATE_DIR/garden.catchup" 2>/dev/null || echo 0)"
stale=0;   [ "$((now - gok))" -gt 86400 ] && stale=1
gfailed=0; [ -f "$STATE_DIR/garden.fail" ] && gfailed=1
if { [ "$stale" = 1 ] || [ "$gfailed" = 1 ]; } && [ "$((now - gtry))" -gt 7200 ]; then
  echo "$now" > "$STATE_DIR/garden.catchup"
  reason=""; [ "$stale" = 1 ] && reason="stale"; [ "$gfailed" = 1 ] && reason="${reason:+$reason+}previous-fail"
  log "harvest: garden catch-up ($reason; last ok $(date -r "$gok" '+%F %H:%M' 2>/dev/null || echo never)) — running"
  bash "$LOOP_DIR/bin/garden.sh" --catch-up
  # Miner catch-up — sequenced after garden, but ONLY if the garden actually SUCCEEDED. garden.sh exits 0
  # even on failure/skip, so trust the state marker, not the exit code: run the miner iff garden.success
  # advanced. --catch-up bypasses the cadence floor (the corpus just changed) but still honors enabled /
  # skip-if-unchanged / rejected-dedup / store.lock. garden.sh is synchronous and releases store.lock
  # before returning, so the two never overlap.
  gok2="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
  if [ "$gok2" -gt "$gok" ] && [ "${SKILL_MINER_ENABLED:-0}" = 1 ]; then
    log "harvest: miner catch-up (sequenced after confirmed garden success)"
    bash "$LOOP_DIR/bin/mine-skills.sh" --catch-up
  fi
fi
log "harvest: nightly pass complete"
