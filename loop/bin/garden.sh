#!/usr/bin/env bash
# Gardener: dedup/merge/prune/re-verify memories + skills; bound MEMORY.md.
# "Success" is explicit: claude returned no is_error AND a fresh, non-empty digest was written
# THIS run. Only then is state/garden.success updated. Failures log "garden: FAILED ..." and are
# visible in `loopctl doctor`. A lock prevents the 03:00 run and a harvest catch-up from overlapping.
set -uo pipefail
. "$HOME/.claude/loop/lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1

tag="${1:-scheduled}"   # "--catch-up" when invoked by harvest
acquire_store_lock "garden-$tag" || { log "garden: memory store busy (garden/miner running) — skip ($tag)"; exit 0; }
trap 'release_store_lock' EXIT

stamp="$(date '+%Y-%m-%d')"
digest="$LOOP_DIR/log/garden-$stamp.md"
start="$(date +%s)"

prompt="$(cat "$LOOP_DIR/prompts/garden.md")"
prompt="${prompt//'{{MODE}}'/$LOOP_MODE}"
prompt="${prompt//'{{MEMORY_DIR}}'/$MEMORY_DIR}"
prompt="${prompt//'{{SKILLS_DIR}}'/$SKILLS_DIR}"
prompt="${prompt//'{{PENDING_SKILLS}}'/$PENDING_SKILLS}"
prompt="${prompt//'{{DIGEST}}'/$digest}"
prompt="${prompt//'{{MAX_LINES}}'/$MEMORY_INDEX_MAX_LINES}"

log "garden: start mode=$LOOP_MODE model=$GARDENER_MODEL ($tag)"
mem_snapshot "pre-garden"   # rollback point before the gardener edits memory-global
raw="$(printf '%s' "$prompt" | claude -p \
  --model "$GARDENER_MODEL" \
  --effort "$GARDENER_EFFORT" \
  --permission-mode bypassPermissions \
  --add-dir "$CLAUDE_HOME" \
  --no-session-persistence \
  --output-format json \
  --allowedTools Read Write Edit Grep Glob 2>/dev/null)"
rc=$?   # pipefail is set, so this is claude's exit status

# Confirmed success requires ALL of: clean exit, parseable JSON, no API error reported, and a
# fresh non-empty digest written THIS run. A timeout / dropped connection (the observed failure)
# yields a non-zero rc and/or non-JSON output — both now fail the run instead of slipping through
# on a stale digest.
dmtime="$(stat -f %m "$digest" 2>/dev/null || echo 0)"
ok=1; reason=""; cost="?"
[ "$rc" -eq 0 ] || { ok=0; reason="claude-rc-$rc"; }
if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
  is_err="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.is_error) else (.is_error // false) end' 2>/dev/null)"
  cost="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.total_cost_usd) else (.total_cost_usd // empty) end' 2>/dev/null)"
  [ "$is_err" = "true" ] && { ok=0; reason="${reason:+$reason,}api-error"; }
else
  ok=0; reason="${reason:+$reason,}invalid-json"
fi
[ -s "$digest" ]                || { ok=0; reason="${reason:+$reason,}no-digest"; }
[ "${dmtime:-0}" -ge "$start" ] || { ok=0; reason="${reason:+$reason,}stale-digest"; }

if [ "$ok" = 1 ]; then
  mem_snapshot "post-garden"
  date +%s > "$STATE_DIR/garden.success"; rm -f "$STATE_DIR/garden.fail"
  log "garden: done (ok) cost=${cost:-?} -> $digest"
else
  mem_snapshot "post-garden-FAILED"   # truthful label; pre-garden snapshot remains the rollback point
  printf '%s|%s' "$(date +%s)" "$reason" > "$STATE_DIR/garden.fail"
  log "garden: FAILED ($reason) cost=${cost:-?} — not marking success; harvest will retry when awake"
fi
