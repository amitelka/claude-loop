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
trap 'rmdir "$lock" 2>/dev/null; rm -f "$slice_raw" "$slice_txt" 2>/dev/null' EXIT

slice_txt="$(mktemp -t loop-slicetxt.XXXXXX)"
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

guard_before="$(loop_manifest)"   # write-scope guard: fingerprint of memory-global + pending + skills
log "review: start session=$session trigger=$trigger mode=$LOOP_MODE model=$REVIEWER_MODEL (writes proposal file)"
raw="$(printf '%s' "$prompt" | claude -p \
  --model "$REVIEWER_MODEL" \
  --effort "$REVIEWER_EFFORT" \
  --permission-mode bypassPermissions \
  --add-dir "$CLAUDE_HOME" \
  --no-session-persistence \
  --output-format json \
  --allowedTools Read Grep Glob Write \
  --disallowedTools Bash Edit Task WebFetch WebSearch NotebookEdit 2>/dev/null)"   # bypassPermissions IGNORES --allowedTools; the slice is UNTRUSTED input → a denylist is the only gate against Bash/exfil
cost="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.total_cost_usd) else (.total_cost_usd // empty) end' 2>/dev/null)"
is_err="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.is_error) else (.is_error // false) end' 2>/dev/null)"

# API/connectivity failure → do NOT advance the watermark; the next harvest retries this session.
if [ "$is_err" = "true" ]; then
  printf '%s' "$raw" > "$proposal.apierror" 2>/dev/null
  log "review: session=$session API error (cost=${cost:-?}) — watermark NOT advanced, will retry"
  exit 0
fi

# Write-scope guard: the reviewer may touch ONLY its proposal artifact (+ log). memory-global, pending,
# and installed skills must be byte-identical before materialize — else abort loudly, don't bless the run.
if [ "$guard_before" != "$(loop_manifest)" ]; then
  log "review: session=$session ANOMALY — reviewer touched memory-global/pending/skills directly; aborting (no materialize/advance)"
  mem_snapshot "reviewer-anomaly-$session"
  exit 0
fi

if [ -f "$proposal" ] && jq -e . "$proposal" >/dev/null 2>&1; then
  log "review: session=$session valid proposal cost=${cost:-?} -> materialize"
  bash "$LOOP_DIR/bin/materialize.sh" "$proposal" "$session" "$cwd"
  [ -n "$wm_line" ] && printf '%s' "$wm_line" > "$STATE_DIR/$session.line"   # advance only on success
else
  printf '%s' "$raw" > "$proposal.noproposal" 2>/dev/null
  log "review: session=$session no valid proposal file (cost=${cost:-?}) — watermark NOT advanced, will retry"
fi
exit 0
