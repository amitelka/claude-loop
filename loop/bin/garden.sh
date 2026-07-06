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
trap 'release_store_lock' EXIT   # garden keeps the FULL-run lock (a multi-file store rewrite must be coherent)

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
ing="$(ingest_external)"; [ "$ing" = clean ] || log "garden: entry ingress=$ing ($tag)"   # #16: reconcile pre-existing external dirt UNDER THE LOCK first (replaces the pre-garden snapshot; gardener runs on a clean store)
# P1-a backstop: if the COMMITTED store is invalid post-ingress, don't spend on the gardener — restore/quarantine can't
# proceed from a broken baseline and any edit would just fail validate. doctor already surfaces `store INVALID`.
if ! validate_store "$MEMORY_DIR" >/dev/null 2>&1; then
  log "garden: store INVALID (committed) — skip, no spend ($tag) (loopctl verify-store)"; exit 0
fi
pre_rev="$(mem_git rev-parse HEAD 2>/dev/null)"   # rollback ref (post-ingress HEAD) + garden-actions sidecar diff base
rm -f "$digest" "$declared"   # F3 + P2: fresh per-run artifacts; a stale declared file must never justify today's drops
zbase="$(zone_fingerprint)"   # #23 tripwire baseline — impossible zones (pending/ + installed skills/); the gardener legitimately writes memory-global + log/, so those are NOT zones
gbase="$(zone_git_fingerprint)"   # #23 .git-only baseline (memory-global/.git + skills/.git) — the RCE surface, checked git-FREE below BEFORE any git op
# #23 seam: worker_spawn centralizes the driver (profile integrity + default-mode + scoped flags). gardener writes
# memory-global/** + log/garden-* (profile-scoped, .git denied); --add-dir SKILLS_DIR to READ installed skills for
# the report (never writes them; --tools keeps Edit for availability). memory bodies are UNTRUSTED input.
raw="$(printf '%s' "$prompt" | worker_spawn gardener "$GARDENER_MODEL" "$GARDENER_EFFORT" "Read,Write,Edit,Grep,Glob" "Bash Task WebFetch WebSearch NotebookEdit" "$SKILLS_DIR" 2>/dev/null)"
rc=$?   # pipefail: worker_spawn's rc (claude's exit status, or EX_PROFILE if the profile is missing/tampered)
[ "$rc" = "$EX_PROFILE" ] && { log "garden: gardener profile unavailable/tampered (${PROFILES_DIR#$HOME/}) — abort, no spend ($tag) (loopctl reprofile)"; exit 1; }

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
# #23 .git tripwire (r5 ordering, git-FREE, runs BEFORE any git op below): a hook/MCP side-effect that rewrites
# memory-global/.git or skills/.git (e.g. core.fsmonitor|filter.clean helper) would detonate on the very git op
# meant to recover — this failure path runs mem_restore_to (git reset/clean) which would EXECUTE the tampered
# config. So detect it here, before actuate/validate/restore, and ABORT HARD with NO git op at all: leave the
# tree + tampered .git as forensic evidence for a human (loopctl doctor / verify-store). No mirror to restore from.
if [ "$gbase" != "$(zone_git_fingerprint)" ]; then
  printf '%s|%s' "$(date +%s)" "git-zone-tamper" > "$STATE_DIR/garden.fail" 2>/dev/null || true
  log "garden: ABORT — memory-global/.git or skills/.git changed during the gardener window (config-tamper class); NO git op run, tree left as forensic evidence ($tag)"
  exit 1
fi
# #23 tripwire: the gardener's writes are platform-scoped to memory-global/** + log/garden-* (deny .git). A change
# to the IMPOSSIBLE zones (pending/ + installed skills/, which the gardener never writes) during its run = an
# ungoverned side-effect (hook/MCP) → FAIL the run fail-closed (memory-global then reverts to pre_rev via the failure
# path). Evidence-only, NO restore machinery. Runs regardless of gardener rc. .git already handled above.
if [ "$zbase" != "$(zone_fingerprint)" ]; then
  ok=0; reason="${reason:+$reason,}impossible-zone-write"
fi

# DECLARED-ACTIONS ACTUATION (P1) — ACTIVE MODE ONLY. The LLM gardener has no delete tool, so it only DECLARES
# prune/merge intent; this deterministic bash actuates it (validate declaration schema/merge-graph/rule-typed/
# ceiling/merge-target FIRST → then rm index line + body), BEFORE validate_store, so the gardener can dedup/prune.
# A bad declaration aborts with ZERO rm → failure path → restore. Order load-bearing: actuate strictly AFTER
# declaration-validate. DRY-RUN: the store must change NOTHING (gardener is report-only) — skip actuation, and if
# the LLM mutated memory-global at all (tracked diff or new untracked file), FAIL → restore (never commit a dry-run edit).
if [ "$ok" = 1 ]; then
  if [ "$LOOP_MODE" = active ]; then
    areason="$(actuate_declared "$MEMORY_DIR" "$pre_rev" "$declared")" || { ok=0; reason="${reason:+$reason,}actuate:$areason"; }
  elif ! mem_git diff --quiet "$pre_rev" -- 2>/dev/null || [ -n "$(mem_git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    ok=0; reason="${reason:+$reason,}dry-run-mutation"
  fi
fi

# Content-integrity gate (validate-THEN-commit): even a clean-exit gardener can mangle the index or drop
# memories. Validate the WORKING TREE against pre-garden BEFORE committing; a failure joins the rc/api/digest
# failure path → auto-restore, never committing a partial mutation as HEAD (the manual-rollback trap). After
# actuation, the declared drops are now OBSERVED here → observed==declared re-confirmed.
[ "$ok" = 1 ] && { vreason="$(validate_store "$MEMORY_DIR" "$pre_rev" "$declared")" || { ok=0; reason="${reason:+$reason,}validate:$vreason"; }; }

if [ "$ok" = 1 ]; then
  mem_snapshot "post-garden"
  garden_actions "$pre_rev" "$(mem_git rev-parse HEAD 2>/dev/null)"   # deterministic prune/merge/trim sidecar
  date +%s > "$STATE_DIR/garden.success"; rm -f "$STATE_DIR/garden.fail"
  rebuild_mem_index "garden"   # derived retriever index; stale index self-heals next write
  log "garden: done (ok) cost=${cost:-?} -> $digest"
else
  # GARDEN-RESTORE leg (#16): the restore below reverts the whole tree to pre_rev, which would SWEEP any peer
  # write that landed in the garden window. The gardener only edits/prunes EXISTING (tracked) bodies, so an
  # untracked file here is a non-gardener (peer) write → preserve it as a recoverable, doctor-visible quarantine
  # item before reverting, instead of burying it in the forensic patch nobody reads.
  ext="$(mem_git ls-files --others --exclude-standard 2>/dev/null)"
  if [ -n "$ext" ]; then
    qd="$QUARANTINE_DIR/garden-swept-$run_id"; mkdir -p "$qd"
    printf 'peer writes reverted on garden FAIL (%s) — recover by hand if wanted\n' "$reason" > "$qd/reason"
    printf '%s\n' "$ext" | while IFS= read -r u; do [ -n "$u" ] && cp -p "$MEMORY_DIR/$u" "$qd/" 2>/dev/null; done
    log "garden: external memory ingress invalid — $(printf '%s\n' "$ext" | grep -c .) peer write(s) parked in ${qd#$HOME/}"
  fi
  mem_restore_to "$pre_rev" "$patch"   # discard corrupt tree → HEAD stays clean at the post-ingress rev
  [ -f "$declared" ] && { printf '\n=== declared-actions.json (this failed run) ===\n'; cat "$declared"; } >> "$patch" 2>/dev/null   # P2: fold the run's declared intent into the forensic bundle
  printf '%s|%s' "$(date +%s)" "$reason" > "$STATE_DIR/garden.fail"
  log "garden: FAILED ($reason) cost=${cost:-?} — restored to pre-garden; harvest will retry when awake"
fi
