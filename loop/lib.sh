#!/usr/bin/env bash
# ~/.claude/loop/lib.sh — shared helpers. Source this; it pulls in config.sh.

_LOOP_SELF="${BASH_SOURCE[0]:-$HOME/.claude/loop/lib.sh}"
LOOP_LIB_DIR="$(cd "$(dirname "$_LOOP_SELF")" 2>/dev/null && pwd)"
[ -f "$LOOP_LIB_DIR/config.sh" ] || LOOP_LIB_DIR="$HOME/.claude/loop"
# shellcheck disable=SC1091
. "$LOOP_LIB_DIR/config.sh"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"   # optional OAuth token for unattended cron

ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG" 2>/dev/null; }

# Counts over a RAW JSONL slice on stdin.
count_tools() { jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .id' 2>/dev/null | wc -l | tr -d ' '; }
count_turns() { jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text")    | "x"' 2>/dev/null | wc -l | tr -d ' '; }

# Render a RAW JSONL slice (stdin) → compact reviewer transcript (stdout). Active branch only
# (drops Esc-Esc rewind forks), drops isMeta noise, keeps Task/Agent subagent returns in full.
render_slice() { /usr/bin/python3 "$LOOP_DIR/bin/render_slice.py" 2>/dev/null; }

pending_skill_count() { find "$PENDING_SKILLS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# memory-global git snapshots (rollback safety, esp. before the gardener mutates it).
mem_git()      { git -C "$MEMORY_DIR" "$@"; }
mem_snapshot() {  # $1 = label
  mem_git rev-parse --git-dir >/dev/null 2>&1 || { mem_git init -q && mem_git config user.email loop@local && mem_git config user.name claude-loop; }
  mem_git add -A 2>/dev/null
  mem_git commit -q -m "${1:-snapshot} $(date '+%Y-%m-%dT%H:%M:%S')" 2>/dev/null || true
}

# ~/.claude/skills git snapshots — same idea as mem_snapshot, so skill patches (yours or loop-proposed)
# and the eventual curator's edits are revertable. The skills dir becomes its own local git repo.
skill_git()      { git -C "$SKILLS_DIR" "$@"; }
skill_snapshot() {  # $1 = label
  skill_git rev-parse --git-dir >/dev/null 2>&1 || { skill_git init -q && skill_git config user.email loop@local && skill_git config user.name claude-loop; }
  skill_git add -A 2>/dev/null
  skill_git commit -q -m "${1:-snapshot} $(date '+%Y-%m-%dT%H:%M:%S')" 2>/dev/null || true
}

# Shared mutex over the memory store: the gardener (rewrites memory-global) and the skill miner
# (reads it) must never run concurrently, in either order. Atomic mkdir; a lock leaked by a crash /
# power-loss is stolen after STALE_LOCK_SECS. acquire returns 0 if acquired, 1 if busy.
STALE_LOCK_SECS="${STALE_LOCK_SECS:-7200}"
acquire_store_lock() {  # $1 = holder label
  local holder="${1:-?}" lock="$STATE_DIR/store.lock" epoch old age now
  mkdir -p "$STATE_DIR" 2>/dev/null; now="$(date +%s)"
  if mkdir "$lock" 2>/dev/null; then printf '%s %s %s\n' "$holder" "$$" "$now" > "$lock/owner" 2>/dev/null; return 0; fi
  epoch="$(awk '{print $3}' "$lock/owner" 2>/dev/null)"; old="$(awk '{print $1}' "$lock/owner" 2>/dev/null)"
  case "$epoch" in ''|*[!0-9]*) return 1;; esac          # no/garbled owner → assume fresh, don't steal
  age=$(( now - epoch )); [ "$age" -gt "$STALE_LOCK_SECS" ] || return 1
  rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 1
  printf '%s %s %s\n' "$holder" "$$" "$now" > "$lock/owner" 2>/dev/null
  log "store-lock: $holder stole stale lock (age ${age}s, was '${old:-?}')"; return 0
}
release_store_lock() { rm -rf "$STATE_DIR/store.lock" 2>/dev/null; }

# Fingerprint of the dirs the reviewer must NOT touch (memory-global + pending + installed skills).
# review.sh asserts this is unchanged across the reviewer run — it may write only its proposal artifact.
loop_manifest() {
  find "$MEMORY_DIR" "$PENDING_MEM" "$PENDING_SKILLS" "$SKILLS_DIR" -type f -exec stat -f '%N|%m|%z' {} + 2>/dev/null | LC_ALL=C sort | shasum | awk '{print $1}'
}

# Skip-if-unchanged fingerprint for the skill miner — the meaningful INPUTS only. Deliberately NOT
# pending/skills: staging proposals is an OUTPUT of mining, so including it would self-invalidate the
# skip (mine → stage → fingerprint moves → mine again). Content-derived, order-stable.
miner_fingerprint() {
  local mh sh uh ph
  mh="$(mem_git rev-parse HEAD 2>/dev/null || echo none)"
  sh="$(skill_git rev-parse HEAD 2>/dev/null || echo none)"
  uh="$(shasum "$STATE_DIR/skill-uses.jsonl" 2>/dev/null | awk '{print $1}')"
  ph="$(shasum "$LOOP_DIR/prompts/mine-skills.md" 2>/dev/null | awk '{print $1}')"
  printf '%s|%s|%s|%s' "$mh" "$sh" "${uh:-none}" "${ph:-none}" | shasum | awk '{print $1}'
}
