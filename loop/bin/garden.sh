#!/usr/bin/env bash
# Weekly gardener: dedup/merge/prune/re-verify memories + skills; bound MEMORY.md.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1

stamp="$(date '+%Y-%m-%d')"
digest="$LOOP_DIR/log/garden-$stamp.md"

prompt="$(cat "$LOOP_DIR/prompts/garden.md")"
prompt="${prompt//'{{MODE}}'/$LOOP_MODE}"
prompt="${prompt//'{{MEMORY_DIR}}'/$MEMORY_DIR}"
prompt="${prompt//'{{SKILLS_DIR}}'/$SKILLS_DIR}"
prompt="${prompt//'{{PENDING_SKILLS}}'/$PENDING_SKILLS}"
prompt="${prompt//'{{DIGEST}}'/$digest}"
prompt="${prompt//'{{MAX_LINES}}'/$MEMORY_INDEX_MAX_LINES}"

log "garden: start mode=$LOOP_MODE model=$GARDENER_MODEL"
mem_snapshot "pre-garden"   # rollback point before the gardener edits memory-global
printf '%s' "$prompt" | claude -p \
  --model "$GARDENER_MODEL" \
  --effort "$GARDENER_EFFORT" \
  --permission-mode bypassPermissions \
  --add-dir "$CLAUDE_HOME" \
  --no-session-persistence \
  --allowedTools Read Write Edit Grep Glob >> "$LOG" 2>&1
mem_snapshot "post-garden"
log "garden: done -> $digest"
