#!/usr/bin/env bash
# ~/.claude/loop/lib.sh — shared helpers. Source this; it pulls in config.sh.

_LOOP_SELF="${BASH_SOURCE[0]:-$HOME/.claude/loop/lib.sh}"
LOOP_LIB_DIR="$(cd "$(dirname "$_LOOP_SELF")" 2>/dev/null && pwd)"
[ -f "$LOOP_LIB_DIR/config.sh" ] || LOOP_LIB_DIR="$HOME/.claude/loop"
# shellcheck disable=SC1091
. "$LOOP_LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LOOP_LIB_DIR/tags.sh"   # canonical log-tag substrings; stats/doctor grep via these (never literals)
[ -f "$ENV_FILE" ] && . "$ENV_FILE"   # optional OAuth token for unattended cron

ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG" 2>/dev/null; }

# ── Kill switch ──────────────────────────────────────────────────────────────
# LOOP_ENABLED is the master switch. The hook path already honors it (on-stop / on-session-end +
# measure_on + the self-heal maybe_* gates). These helpers extend it to the SCHEDULED/DETACHED
# autonomous entry points (launchd-invoked or nohup-spawned), which previously ran regardless — so
# LOOP_ENABLED=0 truly means "whole loop inert" per BEHAVIOR.md. Operator-control commands
# (loopctl status/doctor/rollback/…) deliberately do NOT gate on this — they must work while off.
loop_enabled() { [ "${LOOP_ENABLED:-0}" = "1" ]; }
# Source of truth for the autonomous entry-point set the contract test enforces (tests/kill_switch_test.sh):
# registration-derived ∪ detached workers — garden-then-mine.sh is nohup-spawned, NOT launchd-registered.
# shellcheck disable=SC2034  # consumed cross-file by tests/kill_switch_test.sh, not by runtime code
LOOP_AUTONOMOUS_ENTRYPOINTS=(garden.sh harvest.sh mine-skills.sh garden-then-mine.sh)
guard_loop_enabled() {  # $1 = entry-point label; log one line + exit 0 (fail-open, no work) when disabled
  loop_enabled && return 0
  log "$1: skip: LOOP_ENABLED=0"
  exit 0
}
# Doctor's launchd verdict as a PURE function (enabled + agent count → line; rc 0=ok 1=warn) so the 2×2 is
# unit-testable without touching real launchd state; `loopctl doctor` is a thin caller. See tests/kill_switch_test.sh.
schedule_doctor_verdict() {  # $1=enabled(0/1) $2=launchd agent count
  local en="${1:-0}" n="${2:-0}"
  if [ "$en" = 1 ]; then
    [ "$n" -ge 2 ] && { echo "launchd: $n agents loaded"; return 0; }
    echo "launchd: $n/2 loaded — idle maintenance off; presence self-heal still covers activity (loopctl install-schedule)"; return 1
  fi
  [ "$n" = 0 ] && { echo "launchd: schedule absent — coherent with LOOP_ENABLED=0"; return 0; }
  echo "launchd: $n agent(s) loaded but LOOP_ENABLED=0 — scheduled runs no-op (loopctl uninstall-schedule, or enable)"; return 1
}

# ── Passive measurement (observation window B): log-only telemetry, gated + loop-session-filtered ──
# measure_on: should this event be recorded? Off unless MEASUREMENT_ENABLED and LOOP_ENABLED, and NEVER
# for the loop's own `claude -p` (gardener/reviewer/miner + loop-adjacent harnesses) — they read every
# memory and would swamp read-counts. The opt-out is LOOP_REVIEWER=1 — NOT CLAUDE_CODE_CHILD_SESSION,
# which this environment sets on normal top-level sessions too (it would exclude every real session).
measure_on() {
  [ "${MEASUREMENT_ENABLED:-0}" = 1 ] && [ "${LOOP_ENABLED:-0}" = 1 ] || return 1
  [ -n "${LOOP_REVIEWER:-}" ] && return 1
  return 0
}
measure_append() { mkdir -p "$MEASURE_DIR" 2>/dev/null; printf '%s\n' "$2" >> "$MEASURE_DIR/$1.jsonl" 2>/dev/null; }  # $1=stream, $2=prebuilt json line

# garden-actions sidecar: derive {deleted|added|modified|renamed} memory actions from the pre→post
# garden git diff — DETERMINISTIC, not LLM-emitted (the prose digest already has rationale; this is its
# machine-readable companion). Feeds regret-tracking + prune-class stats. Written on every successful
# garden (gardener telemetry, not measurement-gated). MEMORY.md index churn is skipped (not an action).
sanitize_sid() {   # a hook-provided session_id must NEVER be used as a raw path component (../ traversal).
  local s; s="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-')"   # drop '/' and everything non-filename-safe
  printf '%s' "${s:-nosession}"
}

rebuild_mem_index() {   # (re)build the derived retriever index from the current store; $1 = log-context label.
  [ -d "$MEMORY_DIR" ] || return 0   # ONE place every store mutation (write/rollback/install) refreshes the index
  /usr/bin/python3 "$LOOP_DIR/bin/build_index.py" "$MEMORY_DIR" "$STATE_DIR/mem-index.json" >/dev/null 2>&1 \
    && log "index rebuild (${1:-write})"
}

garden_actions() {  # $1=pre_rev $2=post_rev
  local pre="$1" post="$2" run st old path slug act
  [ -n "$pre" ] && [ -n "$post" ] || return 0
  run="$(date +%s)"; mkdir -p "$STATE_DIR" 2>/dev/null
  mem_git diff --name-status "$pre" "$post" -- '*.md' 2>/dev/null | while IFS="$(printf '\t')" read -r st old path; do [ -n "$path" ] || path="$old"
    case "$path" in */MEMORY.md|MEMORY.md|*/ARCHIVE.md|ARCHIVE.md) continue;; esac   # index files, not memories
    slug="$(basename "$path" .md)"
    case "$st" in D) act=deleted;; A) act=added;; M) act=modified;; R*) act=renamed;; *) act="$st";; esac
    printf '{"v":%s,"ts":%s,"stream":"garden-action","action":"%s","slug":"%s"}\n' "${MEASUREMENT_VERSION:-1}" "$run" "$act" "$slug"
  done >> "$STATE_DIR/garden-actions.jsonl" 2>/dev/null
  # Hot-budget moves: tier = which index lists a slug (not frontmatter), so a promote/demote is an index line
  # crossing MEMORY.md ↔ ARCHIVE.md. Audit it — hot is the one contended tier (POLICY.md curation rules).
  local hpre hpost cpre cpost s
  idx_slugs(){ mem_git show "$1" 2>/dev/null | sed -n 's/.*](\([a-z0-9][a-z0-9-]*\)\.md).*/\1/p'; }
  hpre="$(idx_slugs "$pre:MEMORY.md")";  hpost="$(idx_slugs "$post:MEMORY.md")"
  cpre="$(idx_slugs "$pre:ARCHIVE.md")"; cpost="$(idx_slugs "$post:ARCHIVE.md")"
  { for s in $hpost; do
      printf '%s\n' "$hpre" | grep -qxF "$s" && continue          # already hot pre → not a move
      printf '%s\n' "$cpre" | grep -qxF "$s" || continue          # only if it was cold pre → promoted
      printf '{"v":%s,"ts":%s,"stream":"garden-action","action":"promoted","slug":"%s"}\n' "${MEASUREMENT_VERSION:-1}" "$run" "$s"
    done
    for s in $cpost; do
      printf '%s\n' "$cpre" | grep -qxF "$s" && continue          # already cold pre → not a move
      printf '%s\n' "$hpre" | grep -qxF "$s" || continue          # only if it was hot pre → demoted
      printf '{"v":%s,"ts":%s,"stream":"garden-action","action":"demoted","slug":"%s"}\n' "${MEASUREMENT_VERSION:-1}" "$run" "$s"
    done
  } >> "$STATE_DIR/garden-actions.jsonl" 2>/dev/null
}

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

# ── Self-heal: garden + miner catch-up ─────────────────────────────────────────────────────────
# Same-day recovery when a scheduled run was MISSED (laptop asleep past its slot) or FAILED (transient
# API error), decoupled from launchd's once-a-day wake-fire (the case a stale-only trigger misses:
# harvest already ran, the run failed later, laptop stays awake). Both fire from harvest (nightly) AND
# — because sessions are usually left open, so SessionStart rarely re-fires — from the Stop hook, via
# ONE ordered detached worker (garden first, so a miner retry can't win the store.lock and starve the
# gardener). The *.catchup markers double as 2h cooldowns; store.lock is the hard overlap backstop.

# Garden due? Echoes a reason ("stale" | "previous-fail" | "stale+previous-fail") and returns 0 when a
# catch-up is DUE, else 1 with no output. Due = (no confirmed success in >24h OR the last run failed)
# AND >2h since the last attempt.
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

# Miner due? Independent of the garden — this is "the last automated mine attempt itself crashed,
# retry it" (the garden→miner "corpus changed, re-mine" path lives in garden-then-mine.sh). Due =
# miner enabled AND its last scheduled/catch-up run FAILED (skill-miner.fail) AND >2h since last try.
miner_catchup_due() {
  local now mtry
  [ "${SKILL_MINER_ENABLED:-0}" = 1 ] || return 1
  [ -f "$STATE_DIR/skill-miner.fail" ] || return 1
  now="$(date +%s)"; mtry="$(cat "$STATE_DIR/skill-miner.catchup" 2>/dev/null || echo 0)"
  [ "$((now - mtry))" -gt 7200 ] || return 1
  return 0
}

# Run the garden catch-up if due (synchronous: garden, then sequenced miner, via garden-then-mine.sh).
# Stamps the cooldown BEFORE launching so overlapping turns can't each spawn one. Tradeoff: a launch
# that fails on a trivial bug suppresses retries for 2h — acceptable (prevents storms; shows in doctor).
maybe_garden_catchup() {
  local reason
  [ "${LOOP_ENABLED:-0}" = "1" ] || return 1
  reason="$(garden_catchup_due)" || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null                # else the stamp below fails on a fresh config → no cooldown → spawn storm
  date +%s > "$STATE_DIR/garden.catchup"           # cooldown starts at DECISION, not completion
  log "garden catch-up ($reason) — running"
  bash "$LOOP_DIR/bin/garden-then-mine.sh" "$reason"
}

# Run the miner-fail retry if due (synchronous). --catch-up bypasses the cadence floor but still honors
# skip-if-unchanged / rejected-dedup / store.lock — NOT blunt --force.
maybe_miner_catchup() {
  [ "${LOOP_ENABLED:-0}" = "1" ] || return 1
  miner_catchup_due || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null
  date +%s > "$STATE_DIR/skill-miner.catchup"      # cooldown starts at DECISION, not completion
  log "miner catch-up (previous-fail) — running"
  bash "$LOOP_DIR/bin/mine-skills.sh" --catch-up
}

# Presence-triggered self-heal for the Stop/SessionStart hooks. If EITHER catch-up is due, detach ONE
# worker that runs them in priority order (garden first). Spawns nothing when idle — a near-instant
# no-op on almost every turn (just the two due-checks, no fork).
maybe_selfheal_async() {
  local gate="$STATE_DIR/selfheal.lock" now age
  [ "${LOOP_ENABLED:-0}" = "1" ] || return 1
  { garden_catchup_due >/dev/null 2>&1 || miner_catchup_due; } || return 1
  # Atomic single-worker gate (separate from the garden/miner cooldowns, which the worker only stamps
  # after it starts): stops multiple concurrent Stop/SessionStart hooks — e.g. several open sessions —
  # from each forking a worker in the window before the first stamps its cooldowns. The worker clears
  # this on EXIT; a crashed worker's gate is stolen after 30m (doctor's ownerless-*.lock sweep reaps it too).
  mkdir -p "$STATE_DIR" 2>/dev/null
  if ! mkdir "$gate" 2>/dev/null; then
    now="$(date +%s)"; age=$(( now - $(stat -f %m "$gate" 2>/dev/null || echo "$now") ))
    [ "$age" -gt 1800 ] || return 1                                     # a fresh worker is in flight → don't double-spawn
    rm -rf "$gate" 2>/dev/null; mkdir "$gate" 2>/dev/null || return 1   # steal a stale gate (crashed worker)
  fi
  log "self-heal — spawning detached worker"
  nohup bash "$LOOP_DIR/bin/selfheal.sh" >> "$LOG" 2>&1 < /dev/null & disown
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
