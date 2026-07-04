#!/usr/bin/env bash
# Gardener: dedup/merge/prune/re-verify memories + skills; bound MEMORY.md.
# "Success" is explicit: claude returned no is_error AND a fresh, non-empty digest was written
# THIS run. Only then is state/garden.success updated. Failures log "garden: FAILED ..." and are
# visible in `loopctl doctor`. A lock prevents the 03:00 run and a harvest catch-up from overlapping.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
guard_loop_enabled garden   # kill switch: autonomous entry point no-ops when LOOP_ENABLED=0
export LOOP_REVIEWER=1

tag="${1:-scheduled}"   # "--catch-up" when invoked by harvest
acquire_store_lock "garden-$tag" || { log "garden: memory store busy (garden/miner running) — skip ($tag)"; exit 0; }
trap 'release_store_lock' EXIT

stamp="$(date '+%Y-%m-%d')"; run_id="$(date +%s)"   # run-scoped ids — two gardens in ONE day must not overwrite each other's forensics
digest="$LOOP_DIR/log/garden-$stamp-$run_id.md"
declared="$LOOP_DIR/log/garden-declared-$stamp-$run_id.json"   # gardener's machine-readable intent record (2b)
patch="$LOOP_DIR/log/garden-FAILED-$stamp-$run_id.patch"       # forensic artifact on a failed/invalid run
start="$run_id"

prompt="$(cat "$LOOP_DIR/prompts/garden.md")"
policy="$(cat "$LOOP_DIR/POLICY.md" 2>/dev/null)"   # single source; both prompts interpolate it (no doc↔prompt drift)
prompt="${prompt//'{{POLICY}}'/$policy}"
prompt="${prompt//'{{MODE}}'/$LOOP_MODE}"
prompt="${prompt//'{{MEMORY_DIR}}'/$MEMORY_DIR}"
prompt="${prompt//'{{SKILLS_DIR}}'/$SKILLS_DIR}"
prompt="${prompt//'{{PENDING_SKILLS}}'/$PENDING_SKILLS}"
prompt="${prompt//'{{DIGEST}}'/$digest}"
prompt="${prompt//'{{DECLARED}}'/$declared}"
prompt="${prompt//'{{MAX_LINES}}'/$MEMORY_INDEX_MAX_LINES}"

log "garden: start mode=$LOOP_MODE model=$GARDENER_MODEL ($tag)"
mem_snapshot "pre-garden"   # rollback point before the gardener edits memory-global
pre_rev="$(mem_git rev-parse HEAD 2>/dev/null)"   # for the garden-actions sidecar (diff vs post)
rm -f "$digest" "$declared"   # F3 + P2: fresh per-run artifacts; a stale declared file must never justify today's drops
raw="$(printf '%s' "$prompt" | claude -p \
  --model "$GARDENER_MODEL" \
  --effort "$GARDENER_EFFORT" \
  --permission-mode bypassPermissions \
  --add-dir "$CLAUDE_HOME" \
  --no-session-persistence \
  --output-format json \
  --allowedTools Read Write Edit Grep Glob \
  --disallowedTools Bash Task WebFetch WebSearch NotebookEdit 2>/dev/null)"   # bypassPermissions IGNORES --allowedTools; memory bodies are UNTRUSTED input → denylist is the only gate (keeps Edit — the gardener needs it)
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

# Content-integrity gate (validate-THEN-commit): even a clean-exit gardener can mangle the index or drop
# memories. Validate the WORKING TREE against pre-garden BEFORE committing; a failure joins the rc/api/digest
# failure path → auto-restore, never committing a partial mutation as HEAD (the manual-rollback trap).
[ "$ok" = 1 ] && { vreason="$(validate_store "$MEMORY_DIR" "$pre_rev" "$declared")" || { ok=0; reason="${reason:+$reason,}validate:$vreason"; }; }

if [ "$ok" = 1 ]; then
  mem_snapshot "post-garden"
  garden_actions "$pre_rev" "$(mem_git rev-parse HEAD 2>/dev/null)"   # deterministic prune/merge/trim sidecar
  date +%s > "$STATE_DIR/garden.success"; rm -f "$STATE_DIR/garden.fail"
  rebuild_mem_index "garden"   # derived retriever index; stale index self-heals next write
  log "garden: done (ok) cost=${cost:-?} -> $digest"
else
  mem_restore_to "$pre_rev" "$patch"   # discard corrupt tree → HEAD stays clean at pre-garden
  [ -f "$declared" ] && { printf '\n=== declared-actions.json (this failed run) ===\n'; cat "$declared"; } >> "$patch" 2>/dev/null   # P2: fold the run's declared intent into the forensic bundle
  printf '%s|%s' "$(date +%s)" "$reason" > "$STATE_DIR/garden.fail"
  log "garden: FAILED ($reason) cost=${cost:-?} — restored to pre-garden; harvest will retry when awake"
fi
