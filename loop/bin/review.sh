#!/usr/bin/env bash
# Reviewer: read a transcript slice and WRITE a JSON proposal file (the only file it should touch),
# then hand it to the deterministic gatekeeper/materializer (which is the sole writer of real files).
# Spawned by the Stop/SessionEnd hooks, harvest.sh, or `loopctl review-now`.
# (We use Write rather than stdout-JSON because --json-schema is not enforced in this CLI version and
#  free-form models lapse into prose; writing a file is a reliable, deterministic action.)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1

slice_raw="${1:?slice file}"; session="${2:-manual}"; cwd="${3:-$PWD}"; wm_line="${4:-}"; trigger="${5:-?}"
slice_txt=""
[ -f "$slice_raw" ] || { log "review: no slice file $slice_raw"; exit 1; }

lock="$STATE_DIR/$session.lock"
if ! mkdir "$lock" 2>/dev/null; then log "review: session=$session already running, skip"; rm -f "$slice_raw"; exit 0; fi
trap 'release_store_lock; rmdir "$lock" 2>/dev/null; rm -f "$slice_raw" "$slice_txt" 2>/dev/null' EXIT

# ENTRY (#23 lock-shrink): take a SHORT store-lock hold — reconcile pre-existing external dirt + validate the
# committed store — then RELEASE before the minutes-long model run. The old across-run hold existed to stop another
# actor blessing the reviewer's OWN in-window store write; that threat is now PLATFORM-denied (the reviewer's profile
# forbids writing memory-global), so the hold shrinks. materialize re-acquires + re-ingests + re-validates right
# before writing, so a peer write mid-review only makes the proposal stale (dedup/validate at materialize handles it).
# Store busy at entry (garden/miner/another review) → skip BEFORE the LLM spend (no advance; harvest/catchup retries).
if ! acquire_store_lock "review-$(sanitize_sid "$session")"; then
  log "review: session=$session store busy at entry — skip, no spend/advance"; exit 0
fi
ing="$(ingest_external)"; [ "$ing" = clean ] || log "review: entry ingress=$ing session=$session"   # reconcile pre-existing external dirt
if ! validate_store "$MEMORY_DIR" >/dev/null 2>&1; then   # HEAD-invalid backstop: don't spend on a broken committed store
  release_store_lock; log "review: session=$session store INVALID (committed) — skip, no spend/advance (loopctl verify-store)"; exit 0
fi
release_store_lock   # SHORT hold done — the model run holds no store lock; materialize re-acquires its own

mkdir -p "$STATE_DIR"; slice_txt="$(mktemp "$STATE_DIR/slice.XXXXXX")"   # #23: UNDER LOOP_HOME so the default-mode reviewer (--add-dir LOOP_HOME) can Read it — reads outside LOOP_HOME are denied
render_slice < "$slice_raw" > "$slice_txt"
[ -s "$slice_txt" ] || { log "review: empty rendered slice session=$session"; exit 0; }

ts="$(date '+%Y%m%dT%H%M%S')"
proposal="$LOOP_DIR/proposals/$session-$ts.json"

prompt="$(cat "$LOOP_DIR/prompts/review.md")"
policy="$(cat "$LOOP_DIR/POLICY.md" 2>/dev/null)"   # single source; both prompts interpolate it (no doc↔prompt drift)
prompt="${prompt//'{{POLICY}}'/$policy}"
prompt="${prompt//'{{SLICE_FILE}}'/$slice_txt}"
prompt="${prompt//'{{SESSION}}'/$session}"
prompt="${prompt//'{{CWD}}'/$cwd}"
prompt="${prompt//'{{MEMORY_DIR}}'/$MEMORY_DIR}"
prompt="${prompt//'{{SKILLS_DIR}}'/$SKILLS_DIR}"
prompt="${prompt//'{{PROPOSAL_FILE}}'/$proposal}"

zbase="$(zone_fingerprint)"   # #23 tripwire baseline — the impossible zones (pending/ + installed skills/ + their .git); a change here during the model run = an ungoverned hook/MCP side-effect
log "review: start session=$session trigger=$trigger mode=$LOOP_MODE model=$REVIEWER_MODEL (writes proposal file)"
# #23 seam: worker_spawn centralizes the driver (profile integrity + default-mode + scoped flags). reviewer reads
# only its slice under LOOP_HOME (default --add-dir), Write path-scoped to proposals/ by the profile; slice is UNTRUSTED.
raw="$(printf '%s' "$prompt" | worker_spawn reviewer "$REVIEWER_MODEL" "$REVIEWER_EFFORT" "Read,Grep,Glob,Write" "Bash Edit Task WebFetch WebSearch NotebookEdit" 2>/dev/null)"; rc=$?
[ "$rc" = "$EX_PROFILE" ] && { log "review: session=$session reviewer profile unavailable/tampered — skip, no spend/advance (loopctl reprofile)"; exit 0; }
# #23 TRIPWIRE FIRST (P0-2/r3 ordering): compare the impossible zones IMMEDIATELY after the model call, BEFORE any
# parse/branch — an api-error or no-proposal early exit must NEVER skip it. An in-window change to pending/skills/.git
# is an ungoverned side-effect (hook/MCP/subprocess, outside the model's permission rules) → abort, NO restore (the
# platform should have prevented it; the next store-mutating entry reclassifies any memory-global residue via ingress).
if [ "$zbase" != "$(zone_fingerprint)" ]; then
  log "review: session=$session ANOMALY — impossible-zone (pending/skills/.git) changed during the model window; aborting (no materialize/advance, no restore — see doctor)"
  exit 0
fi
cost="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.total_cost_usd) else (.total_cost_usd // empty) end' 2>/dev/null)"
is_err="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.is_error) else (.is_error // false) end' 2>/dev/null)"

# API/connectivity failure → do NOT advance the watermark; the next harvest retries this session.
if [ "$is_err" = "true" ]; then
  printf '%s' "$raw" > "$proposal.apierror" 2>/dev/null
  log "review: session=$session API error (cost=${cost:-?}) — watermark NOT advanced, will retry"
  exit 0
fi

if [ -f "$proposal" ] && jq -e . "$proposal" >/dev/null 2>&1; then
  log "review: session=$session valid proposal cost=${cost:-?} -> materialize"
  bash "$LOOP_DIR/bin/materialize.sh" "$proposal" "$session" "$cwd"; mrc=$?
  # P0-h: advance the watermark ONLY on materialize landed(0)/clean-noop(10). deferred(20)/failed(30) retry.
  case "$mrc" in
    0|10) [ -n "$wm_line" ] && printf '%s' "$wm_line" > "$STATE_DIR/$session.line"; log "review: session=$session watermark advanced (materialize rc=$mrc)";;
    *)    log "review: session=$session watermark NOT advanced (materialize rc=$mrc — deferred/failed, will retry)";;
  esac
else
  printf '%s' "$raw" > "$proposal.noproposal" 2>/dev/null
  log "review: session=$session no valid proposal file (cost=${cost:-?}) — watermark NOT advanced, will retry"
fi
exit 0
