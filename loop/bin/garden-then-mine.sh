#!/usr/bin/env bash
# garden-then-mine.sh — the catch-up work unit: run the gardener, then (only if it actually
# SUCCEEDED) the skill miner. Shared by harvest (sync) and the Stop/SessionStart hooks (spawned
# detached) so the garden→miner sequencing is identical everywhere. $1 = reason label (for the log).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0

reason="${1:-catch-up}"
gok="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
log "garden-then-mine: garden ($reason; last ok $(date -r "$gok" '+%F %H:%M' 2>/dev/null || echo never))"
bash "$LOOP_DIR/bin/garden.sh" --catch-up

# Miner only if the garden actually advanced garden.success — garden.sh exits 0 even on fail/skip,
# so trust the marker, not the exit code. garden.sh is synchronous and drops store.lock before
# returning, so the miner never overlaps it.
gok2="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
if [ "$gok2" -gt "$gok" ] && [ "${SKILL_MINER_ENABLED:-0}" = 1 ]; then
  log "garden-then-mine: miner (garden success advanced)"
  bash "$LOOP_DIR/bin/mine-skills.sh" --catch-up
fi
