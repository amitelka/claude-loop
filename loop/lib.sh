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
release_store_lock() {  # release ONLY if we can PROVE we own it (owner present AND pid==$$). Missing/other
  # owner → leave it: a stale-steal or mid-acquire race may legitimately own it. A truly-ours-but-lost
  # owner just leaks until the 2h stale-steal reclaims it — safe.
  [ "$(awk '{print $2}' "$STATE_DIR/store.lock/owner" 2>/dev/null)" = "$$" ] && rm -rf "$STATE_DIR/store.lock" 2>/dev/null
  return 0
}

# ── Garden self-heal (catch-up) ──────────────────────────────────────────────────────────────
# Same-day recovery when the daily gardener was MISSED (laptop asleep past 03:00) or its run FAILED
# (transient API error). Fires from harvest (nightly, sync) AND from the Stop/SessionStart hooks
# (async, the moment you're active at the machine) — decoupling recovery from launchd's once-a-day
# wake-fire, which is the case a stale-only trigger misses (harvest already ran, garden failed later,
# laptop stays awake). garden.catchup doubles as the cooldown marker.

# Pure decision. Echoes a reason ("stale" | "previous-fail" | "stale+previous-fail") and returns 0
# when a catch-up is DUE, else returns 1 with no output. Due = (no confirmed success in >24h OR the
# last run failed) AND >2h since the last attempt.
garden_catchup_due() {
  local now gok gtry stale=0 gfailed=0 reason=""
  now="$(date +%s)"
  gok="$(cat "$STATE_DIR/garden.success" 2>/dev/null || echo 0)"
  gtry="$(cat "$STATE_DIR/garden.catchup" 2>/dev/null || echo 0)"
  [ "$((now - gok))" -gt 86400 ] && stale=1
  [ -f "$STATE_DIR/garden.fail" ] && gfailed=1
  { [ "$stale" = 1 ] || [ "$gfailed" = 1 ]; } && [ "$((now - gtry))" -gt 7200 ] || return 1
  [ "$stale" = 1 ] && reason="stale"
  [ "$gfailed" = 1 ] && reason="${reason:+$reason+}previous-fail"
  printf '%s' "$reason"; return 0
}

# Decide + run. $1 = sync (default; blocks — harvest) | async (detach — hooks). Stamps the 2h cooldown
# BEFORE launching so many session-turns can't each spawn a garden; store.lock is the hard backstop
# against overlap either way. Tradeoff: if the launch itself fails on a trivial bug, retries are
# suppressed for 2h — acceptable (prevents storms; the failure shows in the log + loopctl doctor).
maybe_garden_catchup() {
  local mode="${1:-sync}" reason
  [ "${LOOP_ENABLED:-0}" = "1" ] || return 1
  reason="$(garden_catchup_due)" || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null                # else the stamp below fails on a fresh config → no cooldown → spawn storm
  date +%s > "$STATE_DIR/garden.catchup"           # cooldown starts at DECISION, not completion
  if [ "$mode" = async ]; then
    log "garden catch-up ($reason) — spawning detached"
    nohup bash "$LOOP_DIR/bin/garden-then-mine.sh" "$reason" >> "$LOG" 2>&1 < /dev/null & disown
    return 0
  fi
  log "garden catch-up ($reason) — running"
  bash "$LOOP_DIR/bin/garden-then-mine.sh" "$reason"
}

# Fingerprint of the dirs the reviewer must NOT touch (memory-global + pending + installed skills).
# review.sh asserts this is unchanged across the reviewer run — it may write only its proposal artifact.
loop_manifest() {
  find "$MEMORY_DIR" "$PENDING_MEM" "$PENDING_SKILLS" "$SKILLS_DIR" -type f -exec stat -f '%N|%m|%z' {} + 2>/dev/null | LC_ALL=C sort | shasum | awk '{print $1}'
}

# Skip-if-unchanged fingerprint for the skill miner — the meaningful INPUTS only. Hashes the file
# CONTENT of memory-global + installed skills (NOT git HEAD: the miner reads the working tree, so
# hand-edited/uncommitted/untracked memories must register), plus usage + prompt. Deliberately
# excludes pending/skills: staging proposals is an OUTPUT, so including it would self-invalidate the
# skip (mine → stage → fingerprint moves → mine again). Content-derived, order-stable, mtime-agnostic.
miner_fingerprint() {
  local mh sh uh ph
  mh="$(find "$MEMORY_DIR" -type f -name '*.md' -not -path '*/.git/*' -exec shasum {} + 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | shasum | awk '{print $1}')"
  sh="$(find "$SKILLS_DIR" -type f -name '*.md' -not -path '*/.git/*' -exec shasum {} + 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | shasum | awk '{print $1}')"
  uh="$(shasum "$STATE_DIR/skill-uses.jsonl" 2>/dev/null | awk '{print $1}')"
  ph="$(shasum "$LOOP_DIR/prompts/mine-skills.md" 2>/dev/null | awk '{print $1}')"
  printf '%s|%s|%s|%s' "${mh:-none}" "${sh:-none}" "${uh:-none}" "${ph:-none}" | shasum | awk '{print $1}'
}

# Rejected-proposal denylist (keyed name+action) so the miner stops re-proposing ideas you've
# already declined at /review-skills. Visible + clearable — not a silent permanent ban.
REJECT_FILE_NAME="skill-rejections.tsv"   # rows: name<TAB>action<TAB>epoch
skill_is_rejected() {  # $1=name $2=action ; exit 0 if present
  local f="$STATE_DIR/$REJECT_FILE_NAME"; [ -f "$f" ] || return 1
  awk -F'\t' -v n="$1" -v a="${2:-new}" '$1==n && $2==a{f=1} END{exit !f}' "$f"
}
skill_reject_add() {  # $1=name $2=action
  local name="$1" action="${2:-new}"; mkdir -p "$STATE_DIR"
  skill_is_rejected "$name" "$action" && return 0
  printf '%s\t%s\t%s\n' "$name" "$action" "$(date +%s)" >> "$STATE_DIR/$REJECT_FILE_NAME"
}
skill_reject_rm() {  # $1=name $2=action
  local name="$1" action="${2:-new}" f="$STATE_DIR/$REJECT_FILE_NAME" t
  [ -f "$f" ] || return 0
  t="$(mktemp)"; awk -F'\t' -v n="$name" -v a="$action" '!($1==n && $2==a)' "$f" > "$t" && mv "$t" "$f"
}
