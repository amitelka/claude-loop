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

# ── Store integrity (gardener-hardening 2a): deterministic validation + auto-restore ────────────────
# validate_store checks INTEGRITY only — the index is well-formed and nothing vanished unaccounted — NOT
# JUDGMENT (whether a delete was wise; POLICY/regret own that). Both tiers, no model. Echoes a short reason
# on FAILURE (rc 1); rc 0 = valid. $2 (pre_rev) + $3 (declared-actions.json) enable the drop check: every
# dropped slug must be DECLARED (fail-closed), within the volume ceiling, and no rule-typed drop. Uses
# `git -C "$md"` so it is decoupled from the global store.
validate_store() {  # $1=memdir  $2=pre_rev(optional)  $3=declared-actions.json(optional)
  local md="$1" pre="${2:-}" hot cold f slug n refs dup line IFS=$' \t\n'   # local IFS: contain the bash-3.2 while-IFS-read leak
  local kebab='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'   # P0: index targets must be LOCAL kebab slugs (materialize's rule) — no traversal/subdir/absolute
  hot="$md/MEMORY.md"; cold="$md/ARCHIVE.md"
  # (a) both index files present, non-empty, with ≥1 entry — catches a deleted/truncated index (empty-glob class)
  for f in "$hot" "$cold"; do
    [ -f "$f" ] || { echo "missing-index:${f##*/}"; return 1; }
    [ -s "$f" ] || { echo "empty-index:${f##*/}"; return 1; }
    grep -qE '^- \[' "$f" || { echo "no-entries:${f##*/}"; return 1; }
  done
  # (1) FORMAT: each '- [' entry line is exactly ONE well-formed entry head → catches merged/mangled lines.
  # Robust to brackets/parens/em-dashes in a description (a legal desc lacks a full '- [..](..md)' head).
  while IFS= read -r line; do
    n="$(printf '%s' "$line" | grep -oE -- '- \[[^]]*\]\([^)]*\.md\)' | wc -l | tr -d ' ')"
    [ "$n" = 1 ] || { echo "malformed-entry:${line:0:48}"; return 1; }
  done < <(grep -hE '^- \[' "$hot" "$cold" 2>/dev/null)
  # (2) ORPHAN: every referenced slug has a file. DANGLING/DUP: every memory file is in exactly one index line.
  refs="$(grep -hoE '^- \[[^]]*\]\([^)]*\.md\)' "$hot" "$cold" 2>/dev/null | sed -E 's/.*\(([^)]*)\.md\)$/\1/' | LC_ALL=C sort)"
  while IFS= read -r slug; do   # newline-safe (do NOT rely on $refs word-splitting — IFS state varies)
    [ -n "$slug" ] || continue
    [[ "$slug" =~ $kebab ]] || { echo "illegal-slug:$slug"; return 1; }   # P0: reject ../traversal, subdir/x, absolute, illegal chars BEFORE touching the FS
    [ -f "$md/$slug.md" ] || { echo "orphan-index:$slug"; return 1; }
  done <<< "$refs"
  dup="$(printf '%s\n' "$refs" | uniq -d | head -1)"; [ -n "$dup" ] && { echo "dup-index:$dup"; return 1; }
  while IFS= read -r f; do
    slug="${f##*/}"; slug="${slug%.md}"
    case "$slug" in MEMORY|ARCHIVE) continue;; esac
    printf '%s\n' "$refs" | grep -qxF "$slug" || { echo "dangling-file:$slug"; return 1; }
  done < <(find "$md" -maxdepth 1 -name '*.md' 2>/dev/null)
  # (3) DROP CHECK — declared-actions intent contract (2b) + volume ceiling + rule-drop rail. Only when a
  # pre_rev is given AND something actually vanished (zero drops → nothing to check; a missing declared file
  # is only meaningful when a memory disappeared). Three independent gates on the pre→post slug set:
  #   • CEILING (GARDEN_MAX_DROPS): bounds per-run blast radius even for DECLARED drops — the declaring party
  #     is the same LLM we guard, so declared-actions validates ACCOUNTING, not restraint. Operator-raisable.
  #   • INTENT (observed ⊆ declared, $3): every dropped slug must appear in the declared-actions.json. Undeclared
  #     vanish = FAIL, FAIL-CLOSED (no/empty file → every drop undeclared). Declared-not-observed = harmless WARN.
  #   • RULE RAIL (F1): a dropped user|feedback memory is a hard FAIL regardless of declaration — rules leave the
  #     store only UPWARD by human graduation, never by a garden action.
  if [ -n "$pre" ] && git -C "$md" cat-file -e "$pre" 2>/dev/null; then
    local pre_slugs drops nd rt declared="${3:-}" decl
    pre_slugs="$(git -C "$md" show "$pre:MEMORY.md" "$pre:ARCHIVE.md" 2>/dev/null | grep -oE '^- \[[^]]*\]\([^)]*\.md\)' | sed -E 's/.*\(([^)]*)\.md\)$/\1/' | LC_ALL=C sort -u)"
    drops="$(comm -23 <(printf '%s\n' "$pre_slugs") <(printf '%s\n' "$refs" | LC_ALL=C sort -u) | grep -v '^$')"
    nd="$(printf '%s\n' "$drops" | grep -c .)"
    if [ "${nd:-0}" -gt 0 ]; then
      [ "${nd:-0}" -gt "${GARDEN_MAX_DROPS:-3}" ] && { echo "too-many-drops:$nd>${GARDEN_MAX_DROPS:-3}"; return 1; }
      # declared-actions SCHEMA enforcement (P1): top-level array; each entry slug∈kebab, action∈{deleted,merged},
      # `into` (kebab) required when merged. Malformed / non-array / invalid entry ⇒ treat file as MISSING (fail-closed per F3).
      decl=""
      if [ -n "$declared" ] && declared_schema_valid "$declared"; then   # schema + merge-graph (shared contract, can't drift)
        decl="$(jq -r '.[].slug' "$declared" 2>/dev/null | LC_ALL=C sort -u)"
      fi
      while IFS= read -r slug; do   # newline-safe iteration
        [ -n "$slug" ] || continue
        printf '%s\n' "$decl" | grep -qxF "$slug" || { echo "undeclared-drop:$slug"; return 1; }
        rt="$(git -C "$md" show "$pre:$slug.md" 2>/dev/null | sed -n 's/^[[:space:]]*type:[[:space:]]*//p' | head -1)"
        case "$rt" in user|feedback) echo "rule-typed-drop:$slug($rt)"; return 1;; "") echo "untyped-pre-slug:$slug"; return 1;; esac   # P2-1: dropped slug existed pre-run; unparseable type ⇒ fail-closed
      done <<< "$drops"
      if [ -n "$decl" ]; then   # declared-but-not-observed → harmless WARN (said it would delete X, didn't)
        while IFS= read -r slug; do
          [ -n "$slug" ] || continue
          printf '%s\n' "$drops" | grep -qxF "$slug" || log "store-validate: declared-not-observed $slug (WARN)"
        done <<< "$decl"
      fi
    fi
  fi
  return 0
}

# Shared declared-actions schema + MERGE-GRAPH validity — used by BOTH actuate_declared and validate_store so the
# contract can't drift. Enforces: top-level array; NO duplicate .slug; each slug kebab; action deleted|merged;
# merged ⇒ `into` kebab AND into≠slug (no self-merge) AND into ∉ the declared-slug set (the survivor must survive —
# kills [A merged→B, B deleted], and chains A→B→C where B is itself dropped). $1=declared.json. 0 iff valid.
declared_schema_valid() {
  jq -e '
    if type=="array" then
      ([.[].slug]) as $s
      | ($s|length) == ($s|unique|length)
      and all(.[];
          ((.slug|type)=="string" and (.slug|test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")))
          and (.action=="deleted" or .action=="merged")
          and (.action!="merged" or (
                (.into|type)=="string" and (.into|test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))
                and (.into != .slug)
                and ((.into) as $i | ($s|index($i)) == null)
              )))
    else false end' "$1" >/dev/null 2>&1
}

# Actuate the gardener's DECLARED deletes/merges (P1). The LLM has no delete tool (bash-vector denylist), so it
# only DECLARES intent (declared-actions.json) + folds merged content into the target; this deterministic bash
# removes each declared slug's index line + rm's its body, run BEFORE validate_store so a prune/merge actually
# lands (validate_store then re-confirms observed==declared). CALLED ONLY IN active MODE (garden.sh gates it; dry-run
# must change nothing). VALIDATE-THE-DECLARATION-FIRST: bad schema/merge-graph / rule-typed / untyped-pre-slug /
# over-ceiling / merge-into-nothing ⇒ abort with ZERO removal (fail-closed). Phantom (declared slug not present) ⇒
# WARN+skip. Bash-vector stays closed: bodies rm'd ONLY from a validated declaration — an injection can at most
# DECLARE ≤ GARDEN_MAX_DROPS reference-class drops, rule/untyped-pre memories untouchable, full declared+git trail.
# $1=memdir $2=pre_rev $3=declared.json ; echoes a reason + returns 1 on abort. Merge-FOLD quality is OUT of scope (2c).
actuate_declared() {
  local md="$1" pre="${2:-}" declared="${3:-}" slug act into rt n idx tmp IFS=$' \t\n'
  local hot="$md/MEMORY.md" cold="$md/ARCHIVE.md"
  [ -n "$declared" ] && [ -f "$declared" ] || return 0   # no declaration → in-place edits only; nothing to actuate
  declared_schema_valid "$declared" || { echo "bad-declared-schema"; return 1; }   # schema + merge-graph (dup/self/into∉drops)
  # CEILING on the DECLARED drop count (F2), UNIQUE slugs (dup rejected above → == length) — bound blast radius first.
  n="$(jq '[.[]|select(.action=="deleted" or .action=="merged")|.slug]|unique|length' "$declared" 2>/dev/null)"
  [ "${n:-0}" -le "${GARDEN_MAX_DROPS:-3}" ] || { echo "too-many-declared:$n>${GARDEN_MAX_DROPS:-3}"; return 1; }
  # PASS 1 — validate every entry, NO mutation: rule/untyped rail (from PRE-RUN snapshot) + merge-target-exists.
  while IFS=$'\t' read -r slug act into; do
    [ -n "$slug" ] || continue
    if git -C "$md" cat-file -e "$pre:$slug.md" 2>/dev/null; then   # existed PRE-RUN → the rule rail applies
      rt="$(git -C "$md" show "$pre:$slug.md" 2>/dev/null | sed -n 's/^[[:space:]]*type:[[:space:]]*//p' | head -1)"
      case "$rt" in
        user|feedback) echo "rule-typed-declared:$slug($rt)"; return 1;;
        "") echo "untyped-pre-slug:$slug"; return 1;;   # P2-1: can't confirm it's safe to delete → fail-closed
      esac
    fi   # else: new-this-run slug → not a pre-run drop → deletion allowed
    [ "$act" = merged ] && [ ! -f "$md/$into.md" ] && { echo "merge-into-missing:$slug->$into"; return 1; }
  done < <(jq -r '.[]|select(.action=="deleted" or .action=="merged")|[.slug,.action,(.into//"")]|@tsv' "$declared" 2>/dev/null)
  # PASS 2 — ACTUATE, idempotent delete-if-present: drop the index line from both indexes + rm the body. Phantom
  # (body absent) = WARN+skip. Removals are working-tree only; post-garden mem_snapshot (git add -A) commits them.
  while IFS=$'\t' read -r slug act into; do
    [ -n "$slug" ] || continue
    [ -f "$md/$slug.md" ] || { log "garden-actuate: declared $act '$slug' not present — skip (WARN)"; continue; }
    for idx in "$hot" "$cold"; do
      [ -f "$idx" ] || continue
      grep_v_inplace "](${slug}.md)" "$idx"   # P0-3: rc1 (removed the only entry) is success — was `&& mv` → silent no-op + temp litter
    done
    rm -f "$md/$slug.md"
    log "garden-actuate: $act '$slug'${into:+ into '$into'} — removed index line + body"
  done < <(jq -r '.[]|select(.action=="deleted" or .action=="merged")|[.slug,.action,(.into//"")]|@tsv' "$declared" 2>/dev/null)
  return 0
}

# Discard the memory-global working tree back to a committed snapshot, leaving NO untracked orphans, after
# dumping a forensic patch (tracked diff vs pre + untracked bodies). Used by garden.sh + materialize.sh on a
# failed/invalid run so corruption is NEVER committed as HEAD (the manual-rollback trap). reset --hard also
# covers a gardener that committed mid-run. $1=pre_rev $2=forensic patch path.
mem_restore_to() {
  local pre="$1" patch="${2:-/dev/null}" u IFS=$' \t\n'   # local IFS: contain the bash-3.2 while-IFS-read leak
  { mem_git diff "$pre" 2>/dev/null
    mem_git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r u; do
      printf '\n=== untracked: %s ===\n' "$u"; cat "$MEMORY_DIR/$u" 2>/dev/null
    done
  } > "$patch" 2>/dev/null
  mem_git reset --hard "$pre" >/dev/null 2>&1     # HEAD+index+tree → pre (discards a gardener commit too)
  mem_git clean -fd >/dev/null 2>&1               # remove untracked survivors (NOT -x — keep gitignored)
  rebuild_mem_index "restore"
  log "store-restore: reset to $pre (forensic: ${patch#$HOME/})"
}

# ── External-memory ingress (#16) ────────────────────────────────────────────────────────────────────
# Peer agents are FIRST-CLASS producers: they write memory bodies straight into memory-global. At every
# store-mutating ENTRY, UNDER THE STORE LOCK, ingest_external reconciles any PRE-EXISTING dirty tree to a
# valid, committed store BEFORE the reviewer/gardener runs — so peer memories land promptly and the loop
# always operates on a clean baseline (killing the old mem_snapshot commit-as-is poison path). Deterministic,
# no LLM, NO WALL-CLOCK: git working-tree state is the only signal (no-mtime rail). IN-WINDOW dirt (born
# DURING a reviewer run) is NEVER routed here — that path parks, never auto-blesses (reviewer has Write under bypass).
LOOP_SECRET_RE='sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{24,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]'
LOOP_KEBAB_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'

# Frontmatter helpers (P2): scope key extraction to the FIRST ---…--- block, so a `type:`/`description:` quoted in
# body prose or a fenced code block (loop-self memories do exactly this) can't be misread as a frontmatter field.
frontmatter_block() { awk 'NR==1 && $0=="---"{fm=1; next} fm && $0=="---"{exit} fm' "$1" 2>/dev/null; }
frontmatter_value() { frontmatter_block "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -1; }  # $1=file $2=key → first value

# TYPE ROUTER: declared frontmatter type → tier index path (feedback|user→hot, project|reference→cold).
# BROKEN (missing / non-enum / CONFLICTING >1 distinct type) → rc 1, no output. Deterministic, not semantic.
mem_router_index() {  # $1=body file
  local t
  t="$(frontmatter_block "$1" | sed -n 's/^[[:space:]]*type:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | awk 'NF' | LC_ALL=C sort -u)"   # ALL type lines in the block → conflict detection
  case "$t" in
    feedback|user)     printf '%s' "$MEMORY_DIR/MEMORY.md";;
    project|reference) printf '%s' "$MEMORY_DIR/ARCHIVE.md";;
    *) return 1;;   # "" (missing/unparseable) | multiple distinct lines (conflicting) | unknown enum
  esac
}

# Quarantine a dirty artifact + reason into QUARANTINE_DIR (OUTSIDE the tripwire zones + the store) so a park can
# never itself trip the tripwire / feed back into validate_store. Content preserved for hand-recovery. Epoch is
# only a unique dir NAME (not a decision input) — no-mtime rail intact.
mem_quarantine() {  # $1=label $2=reason $3..=files to preserve (absolute)
  local label="$1" reason="$2" dir f; shift 2
  dir="$QUARANTINE_DIR/$(date +%s)-$$-$(sanitize_sid "$label")"; mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$reason" > "$dir/reason" 2>/dev/null
  for f in "$@"; do [ -e "$f" ] && cp -p "$f" "$dir/" 2>/dev/null; done
  log "ingress: quarantine '$label' ($reason) -> ${dir#$HOME/}"
}

# Delete fixed-string-matching lines from a file, in place. P0-3: `grep -v` returns rc 1 when it selects ZERO lines
# (i.e. it removed EVERY line — e.g. a single-entry index) — that is SUCCESS, not error, so the mv must NOT be gated
# on `&&`. Only a real grep/IO failure (rc≥2) aborts (leaving the original intact, no temp litter).
grep_v_inplace() {  # $1=fixed-string pattern  $2=file
  local pat="$1" f="$2" tmp="$2.strip.$$" g
  grep -vF "$pat" "$f" > "$tmp" 2>/dev/null; g=$?
  [ "$g" -le 1 ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}
# Surgically drop ALL pointer lines for a slug from BOTH indexes (operator lines for OTHER slugs survive —
# never a whole-file checkout of an index, R2/P0-b).
mem_strip_index_lines() {  # $1=slug
  local slug="$1" idx
  for idx in "$MEMORY_DIR/MEMORY.md" "$MEMORY_DIR/ARCHIVE.md"; do
    [ -f "$idx" ] || continue
    grep_v_inplace "](${slug}.md)" "$idx"
  done
}
# Pointer prose is OPERATOR-CURATED and must survive (hard rail): the router only decides WHERE a pointer lives,
# it NEVER rewrites the prose. Description-derived text is used ONLY to CREATE a brand-new pointer (no line anywhere).
mem_desc_of() {  # $1=slug → unquoted FRONTMATTER description of the body (fence-scoped, P2)
  local d; d="$(frontmatter_value "$MEMORY_DIR/$1.md" description)"
  d="${d%\"}"; d="${d#\"}"; d="${d//\\\"/\"}"; printf '%s' "$d"
}
mem_head_index_line() { { mem_git show "HEAD:MEMORY.md" 2>/dev/null; mem_git show "HEAD:ARCHIVE.md" 2>/dev/null; } | grep -F "](${1}.md)" | head -1; }  # HEAD's EXACT pointer line, verbatim
mem_head_index_tier() {  # tier path HEAD listed the slug in (rc1 = none)
  mem_git show "HEAD:MEMORY.md" 2>/dev/null | grep -qF "](${1}.md)" && { printf '%s' "$MEMORY_DIR/MEMORY.md"; return 0; }
  mem_git show "HEAD:ARCHIVE.md" 2>/dev/null | grep -qF "](${1}.md)" && { printf '%s' "$MEMORY_DIR/ARCHIVE.md"; return 0; }
  return 1
}
# RESTORE path (deletion / broken-tracked): restore HEAD's EXACT pointer line into HEAD's tier — verbatim, never
# regenerate ("restore means restore"). Fallback CREATE only if HEAD had no line (an invalid pre-state).
# KNOWN (P2-4, accepted): the restored line is re-APPENDED (index end) — prose byte-identical, POSITION not preserved
# (matters only once operators group index sections). Related: an operator hand-MOVING a pointer cross-tier bounces
# back by design — the body's declared `type` is authoritative for tier; re-tier by editing the body's type, not the index.
mem_restore_head_line() {  # $1=slug
  local slug="$1" hl ht idx
  mem_strip_index_lines "$slug"
  hl="$(mem_head_index_line "$slug")"; ht="$(mem_head_index_tier "$slug")"
  if [ -n "$hl" ] && [ -n "$ht" ]; then printf '%s\n' "$hl" >> "$ht"
  elif [ -f "$MEMORY_DIR/$slug.md" ] && idx="$(mem_router_index "$MEMORY_DIR/$slug.md")"; then
    printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$(mem_desc_of "$slug")" >> "$idx"
  fi
}
# PRESENT valid peer body: preserve the pointer PROSE, router only fixes WHERE it lives (fable ruling a-d).
#   (a) 1 line, correct tier → touch nothing (byte-identical, position kept) · (b) 1 line, wrong tier → MOVE verbatim
#   (c) 0 lines → CREATE from body description in router tier · (d) duplicates → keep HEAD-matching text else a
#   correct-tier line else the first; drop the rest.
mem_reconcile_present_line() {  # $1=slug
  local slug="$1" correct hot cold nhot ncold n want hl
  correct="$(mem_router_index "$MEMORY_DIR/$slug.md")" || return 1
  hot="$(grep -F "](${slug}.md)" "$MEMORY_DIR/MEMORY.md" 2>/dev/null)"
  cold="$(grep -F "](${slug}.md)" "$MEMORY_DIR/ARCHIVE.md" 2>/dev/null)"
  nhot="$(printf '%s' "$hot" | grep -c .)"; ncold="$(printf '%s' "$cold" | grep -c .)"; n=$(( nhot + ncold ))
  if [ "$n" -eq 1 ]; then
    { [ "$correct" = "$MEMORY_DIR/MEMORY.md" ] && [ "$nhot" -eq 1 ]; } && return 0   # (a)
    { [ "$correct" = "$MEMORY_DIR/ARCHIVE.md" ] && [ "$ncold" -eq 1 ]; } && return 0  # (a)
    want="${hot:-$cold}"; mem_strip_index_lines "$slug"; printf '%s\n' "$want" >> "$correct"; return 0   # (b) move verbatim
  fi
  if [ "$n" -eq 0 ]; then printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$(mem_desc_of "$slug")" >> "$correct"; return 0; fi   # (c) create
  hl="$(mem_head_index_line "$slug")"   # (d) duplicates
  if [ -n "$hl" ] && printf '%s\n%s\n' "$hot" "$cold" | grep -qxF "$hl"; then want="$hl"
  else want="$(grep -F "](${slug}.md)" "$correct" 2>/dev/null | head -1)"; [ -z "$want" ] && want="$(printf '%s\n%s\n' "$hot" "$cold" | grep -v '^$' | head -1)"; fi
  mem_strip_index_lines "$slug"; printf '%s\n' "$want" >> "$correct"
}

# Per-file INGRESS validation (lighter than validate_store: a missing/wrong-tier index line is TOLERATED here —
# it's the normal new-peer-body case, phase-2 reconciles it). rc 0 = a valid body we can adopt as source of truth.
ingress_body_ok() {  # $1=body file (absolute)
  local f="$1" slug
  [ -f "$f" ] && [ ! -L "$f" ] || return 1                                   # P2: no symlink (no path escape)
  slug="${f##*/}"; slug="${slug%.md}"
  [[ "$slug" =~ $LOOP_KEBAB_RE ]] || return 1                                # local kebab slug (filename only)
  [ "$(head -1 "$f" 2>/dev/null)" = '---' ] || return 1                      # frontmatter opens
  mem_router_index "$f" >/dev/null || return 1                              # type present + enum + not conflicting
  [ -n "$(frontmatter_value "$f" description)" ] || return 1                # description present (fence-scoped, P2)
  awk 'NR>1 && $0=="---"{seen=1;next} seen&&NF{ok=1} END{exit !ok}' "$f" || return 1   # non-empty body past the fence
  grep -qiE "$LOOP_SECRET_RE" "$f" && return 1                               # no secret-like content
  return 0
}

# Reconcile pre-existing dirty memory-global state at a mutator ENTRY. CALLER MUST HOLD THE STORE LOCK.
# Echoes a status word (clean | ingested | parked | invalid) — NEVER advances a watermark. 6-step canonical flow.
ingest_external() {
  mem_git rev-parse --git-dir >/dev/null 2>&1 || { mem_git init -q; mem_git config user.email loop@local; mem_git config user.name claude-loop; }
  # P0-1: NEVER `add -A` on init — that is commit-as-is reborn (a fresh store carrying junk would commit it
  # unvalidated as the baseline). Empty ROOT commit only → HEAD exists → fall through to the NORMAL enumeration
  # below (everything is untracked → junk parks, valid bodies classify, the validated explicit-path commit becomes
  # the REAL first baseline).
  mem_git rev-parse HEAD >/dev/null 2>&1 || mem_git commit -q --allow-empty -m "ingress-init $(date '+%Y-%m-%dT%H:%M:%S')" >/dev/null 2>&1
  local head status_lines line st path slug body tracked affected="" parked=0 ingested=0 addpaths=() IFS=$' \t\n'
  head="$(mem_git rev-parse HEAD 2>/dev/null)" || { printf 'clean'; return 0; }
  status_lines="$(mem_git status --porcelain --untracked-files=all 2>/dev/null)"
  [ -n "$status_lines" ] || { printf 'clean'; return 0; }

  # (1)-(2) enumerate dirty bodies → affected SLUGS; illegal-named junk (the uppercase-IMPL incident) is
  # untracked-only (validate_store bars it from HEAD) → quarantine+remove right here, never enters the slug set.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    st="${line:0:2}"; path="${line:3}"; path="${path#\"}"; path="${path%\"}"
    # The store is FLAT top-level *.md. Anything else dirty (P1-2) — a subdir file (validate_store is maxdepth-1 so
    # would never object, and slug→body path would mismap) or a non-.md file — is non-standard junk → quarantine+remove.
    # (A junk file can only ever be UNTRACKED post-ship — ingress parks it, explicit staging never adds it — so this
    # rm is on an untracked file; a hypothetical TRACKED junk deletion by a peer would leave an uncommitted deletion,
    # but that state is unreachable once the store ships clean.)
    case "$path" in
      MEMORY.md|ARCHIVE.md) continue;;                                                                                  # indexes → changed-slug scan below
      */*)  mem_quarantine "subdir-dirt" "subdir-not-allowed" "$MEMORY_DIR/$path"; rm -f "$MEMORY_DIR/$path"; parked=1; continue;;
      *.md) ;;                                                                                                          # top-level memory body
      *)    mem_quarantine "nonmd-dirt" "non-md-not-allowed" "$MEMORY_DIR/$path"; rm -f "$MEMORY_DIR/$path"; parked=1; continue;;
    esac
    slug="${path%.md}"                                                                                                 # top-level (no slash) → basename is the slug
    if ! [[ "$slug" =~ $LOOP_KEBAB_RE ]]; then
      mem_quarantine "$slug" "illegal-slug" "$MEMORY_DIR/$path"; rm -f "$MEMORY_DIR/$path"; parked=1; continue          # e.g. the uppercase-IMPL incident
    fi
    affected="$affected$slug"$'\n'
  done <<< "$status_lines"
  # index-only dirt: slugs whose pointer line was ADDED or REMOVED vs HEAD. `git diff HEAD` MISSES a fresh untracked
  # index (P0-1 fresh-store case), so compare HEAD's index slug-set against the WORKING-TREE index slug-set instead:
  # comm -3 = slugs in exactly one side (added ⇒ present-only / removed ⇒ HEAD-only), each of which needs reconciling.
  local head_idx wt_idx
  head_idx="$( { mem_git show HEAD:MEMORY.md 2>/dev/null; mem_git show HEAD:ARCHIVE.md 2>/dev/null; } | grep -oE '\]\([a-z0-9-]+\.md\)' | sed -E 's/\]\(([a-z0-9-]+)\.md\)/\1/' | LC_ALL=C sort -u)"
  wt_idx="$( cat "$MEMORY_DIR/MEMORY.md" "$MEMORY_DIR/ARCHIVE.md" 2>/dev/null | grep -oE '\]\([a-z0-9-]+\.md\)' | sed -E 's/\]\(([a-z0-9-]+)\.md\)/\1/' | LC_ALL=C sort -u)"
  affected="$affected$(comm -3 <(printf '%s\n' "$head_idx") <(printf '%s\n' "$wt_idx") | sed 's/^\t//')"$'\n'
  affected="$(printf '%s\n' "$affected" | grep -v '^$' | LC_ALL=C sort -u)"

  # (3)-(4) reconcile each affected slug from its body's ground truth, then re-derive its index line.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    body="$MEMORY_DIR/$slug.md"; tracked=0
    mem_git cat-file -e "HEAD:$slug.md" 2>/dev/null && tracked=1
    if [ -f "$body" ]; then
      if ingress_body_ok "$body"; then
        mem_reconcile_present_line "$slug"                 # VALID peer body = source of truth; preserve line prose, fix placement
        ingested=1; addpaths+=("$slug.md")
      else
        mem_quarantine "$slug" "broken-body" "$body"       # BROKEN → park
        if [ "$tracked" = 1 ]; then                        # tracked: restore HEAD's body + exact pointer line (verbatim)
          mem_git checkout HEAD -- "$slug.md" 2>/dev/null; mem_restore_head_line "$slug"; addpaths+=("$slug.md")
        else rm -f "$body"; mem_strip_index_lines "$slug"; fi   # untracked junk gone → drop any peer pointer for it
        parked=1
      fi
    elif [ "$tracked" = 1 ]; then
      mem_quarantine "$slug" "deletion-attempt"            # committed body deleted → NEVER honor (F1) → restore verbatim
      mem_git checkout HEAD -- "$slug.md" 2>/dev/null; mem_restore_head_line "$slug"; addpaths+=("$slug.md"); parked=1
    else
      mem_strip_index_lines "$slug"                        # phantom pointer for a body that never existed → drop it
    fi
  done <<< "$affected"

  # (5) commit the reconciled result under validate_store, else fail-closed restore (never commit invalid).
  if mem_git diff --quiet HEAD -- 2>/dev/null && [ -z "$(mem_git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    rebuild_mem_index "ingress-restore"
    [ "$parked" = 1 ] && { printf 'parked'; return 0; }; printf 'clean'; return 0   # everything parked/restored → tree back to HEAD
  fi
  local vreason
  if vreason="$(validate_store "$MEMORY_DIR")"; then
    # EXPLICIT paths only (P0-c, never add -A). Residual accepted window (DOCUMENTED, xhigh): a peer write to an
    # INDEX file (MEMORY.md/ARCHIVE.md) between this validate and the `git add` rides inside the explicitly-staged
    # index — bounded to the two index files (bodies can't ride in), reviewed-nightly, non-poison; accepted.
    if [ "${#addpaths[@]}" -gt 0 ]; then mem_git add -- MEMORY.md ARCHIVE.md "${addpaths[@]}" >/dev/null 2>&1
    else mem_git add -- MEMORY.md ARCHIVE.md >/dev/null 2>&1; fi
    mem_git commit -qm "external-memory-ingress $(date '+%Y-%m-%dT%H:%M:%S')" >/dev/null 2>&1
    rebuild_mem_index "ingress"
    log "ingress: committed external-memory-ingress (ingested=$ingested parked=$parked)"
    printf 'ingested'; return 0
  else
    mem_quarantine "ingress" "validate-fail:$vreason"     # reconciliation still invalid → preserve + revert all
    mem_restore_to "$head" "$QUARANTINE_DIR/ingress-invalid-$$.patch"
    log "ingress: INVALID after reconcile ($vreason) — reverted to $head, dirt quarantined"
    printf 'invalid'; return 0
  fi
}

# ── In-window tripwire (#23) ────────────────────────────────────────────────────────────────────────
# #16's mirror/restore guard is DELETED: worker write boundaries are now PLATFORM-enforced (default mode + scoped
# permissions.allow), so a worker's own out-of-scope write is DENIED, not committed-then-reverted. What remains is a
# cheap EVIDENCE-ONLY canary over the IMPOSSIBLE ZONES — human-facing pending/ + installed skills/, which no worker
# writes during its model run and no legitimate PEER writes. A change there means an UNGOVERNED side-effect
# (hook/MCP/subprocess — outside the model's permission rules) reached human-facing state → the caller logs ANOMALY
# + aborts the run, NO restore (the platform should have made it impossible; detecting the impossible is the point;
# the next store-mutating entry reclassifies any residue via ingress). memory-global is NEVER a zone — mid-run store
# changes are EXPECTED peer traffic, reconciled by ingest_external, never a tripwire abort.
zone_fingerprint() {  # content fingerprint of the impossible zones; stable string for equality-compare.
  # INCLUDES .git of the guarded roots (fable ruling): platform perms govern the MODEL's tool calls only — a
  # hook/MCP/subprocess side-effect is plain bash and can write .git/config (the core.fsmonitor|filter.clean helper
  # a later git op would run), which with the mirror deleted has NO other detector. memory-global BODIES stay out
  # (peer traffic, ingress-reconciled); only memory-global/.git is watched. pending/ + skills/ (incl skills/.git) fully.
  { find "$PENDING_MEM" "$PENDING_SKILLS" "$SKILLS_DIR" -type f -exec shasum {} + 2>/dev/null
    find "$MEMORY_DIR/.git" -type f -exec shasum {} + 2>/dev/null
  } | sed -E 's/^([0-9a-f]+)  (.*)$/\2\t\1/' | LC_ALL=C sort
}
# Just the .git RCE surface (memory-global/.git + skills/.git). A worker whose failure path runs a git op (garden's
# mem_restore_to) checks THIS first, git-FREE, and aborts BEFORE that git op — else a tampered .git/config executes
# on the very restore meant to recover (the r5 ordering lesson). review/miner need only zone_fingerprint: they exit
# before any git op on any hit, so a .git tamper there can't detonate.
zone_git_fingerprint() {
  find "$MEMORY_DIR/.git" "$SKILLS_DIR/.git" -type f -exec shasum {} + 2>/dev/null \
    | sed -E 's/^([0-9a-f]+)  (.*)$/\2\t\1/' | LC_ALL=C sort
}

# ── Worker permission profiles (#23) ──────────────────────────────────────────────────────────────
# Per-worker least-privilege profiles: repo TEMPLATES ($POLICY_DIR/<worker>.permissions.json, @@LH@@ placeholder)
# are MATERIALIZED with the machine's realpath-resolved LOOP_HOME into $PROFILES_DIR at install/update/`loopctl
# reprofile`. Workers then spawn `claude -p --settings <materialized>` in DEFAULT mode (no bypass) so the platform
# enforces the write boundary. @@LH@@ = realpath(LOOP_HOME) minus its leading slash — the //-absolute rule form;
# realpath resolves the /tmp→/private/tmp symlink mismatch that otherwise silently DENIES in-scope writes.
loop_abs() { cd "$LOOP_HOME" 2>/dev/null && pwd -P; }   # realpath of LOOP_HOME (symlink-resolved), for the // rule form
# The SINGLE render path: a template + realpath(LOOP_HOME) → the exact profile bytes. materialize writes it;
# worker_profile/profiles_fresh compare against it. One code path ⇒ no materialize-vs-verify drift.
_render_profile() { local tpl="$1" lh; lh="$(loop_abs)" || return 1; sed "s#@@LH@@#${lh#/}#g" "$tpl"; }
materialize_profiles() {  # regenerate $PROFILES_DIR from the templates + the current realpath(LOOP_HOME)
  local tpl out; loop_abs >/dev/null || { log "profiles: LOOP_HOME unresolved ($LOOP_HOME)"; return 1; }
  mkdir -p "$PROFILES_DIR" || return 1
  for tpl in "$POLICY_DIR"/*.permissions.json; do
    [ -f "$tpl" ] || continue
    out="$PROFILES_DIR/$(basename "$tpl")"
    _render_profile "$tpl" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || { rm -f "$out.tmp"; log "profiles: materialize failed $tpl"; return 1; }
  done
  log "profiles: materialized $(find "$PROFILES_DIR" -name '*.permissions.json' 2>/dev/null | wc -l | tr -d ' ') → ${PROFILES_DIR#$HOME/} (LOOP_HOME=$(loop_abs))"
}
# P0-1 (integrity ≠ freshness): a materialized profile is a load-bearing MUTABLE control file. Checking only that
# the realpath prefix is present lets an ADDED allow entry pass as "fresh" while workers consume it. So compare
# BYTE-FOR-BYTE against a fresh render of the template — any drift (extra grant, edited scope) fails. Enforced at
# BOTH doctor (profiles_fresh) AND worker spawn (worker_profile, fail-closed): the worker refuses a tampered profile.
worker_profile() {  # echo the profile path IFF it byte-exactly equals its template render; rc1 (fail-closed) otherwise
  local tpl="$POLICY_DIR/$1.permissions.json" m="$PROFILES_DIR/$1.permissions.json"
  [ -f "$tpl" ] && [ -f "$m" ] || return 1
  _render_profile "$tpl" 2>/dev/null | cmp -s - "$m" || return 1   # missing/added/edited rule ⇒ not byte-exact ⇒ refuse
  printf '%s' "$m"
}
# `loopctl doctor` freshness: every template has a materialized profile that is byte-exact vs its render.
profiles_fresh() {  # rc0 = fresh+intact; echoes a reason otherwise
  local tpl w
  for tpl in "$POLICY_DIR"/*.permissions.json; do
    [ -f "$tpl" ] || continue
    w="$(basename "$tpl" .permissions.json)"
    [ -f "$PROFILES_DIR/$w.permissions.json" ] || { echo "missing:$w"; return 1; }
    worker_profile "$w" >/dev/null 2>&1 || { echo "tampered-or-stale:$w"; return 1; }
  done
  return 0
}
# ══ DRIVER CONTRACT — the worker-spawn seam (#23) ═══════════════════════════════════════════════════
# The ONE place any harness-specific spawn lives. Adding a driver (e.g. Codex `exec`) = implementing THIS
# interface, NOT editing the three worker flows (review/garden/mine). The driver-blind core — ingress, gatekeeper
# + exit contract, validate_store, locks, the tripwire zones, quarantine, watermarks, the scorer — never changes.
# Rationale: ARCHITECTURE.md "Homes / driver contract" + docs/decisions/de-bypass-relocation.md.
#
#   SIGNATURE   <prompt on stdin> | worker_spawn <worker> <model> <effort> <tools-allowlist-csv> <denylist-space-sep> [extra read-dirs...]
#   STDIN/OUT   prompt in on stdin → the driver's JSON result on stdout (Claude: --output-format json, the
#               object-or-array the workers parse with jq). rc = driver failure (non-zero), or EX_PROFILE when
#               the write-scope guarantee can't be established → fail-closed, NO spawn.
#   WRITE SCOPE (load-bearing) the spawned worker may write ONLY its per-worker scope — reviewer/miner → proposals/;
#               gardener → memory-global/** + log/garden-*, with memory-global/.git denied — enforced by the DRIVER's
#               OWN mechanism (Claude: a materialized permission profile, byte-exact-verified here at spawn; another
#               driver: its own sandbox/policy equivalent). The core does NOT re-check the model's writes — this is it.
#   READ SCOPE  the driver must ensure the worker can read LOOP_HOME + declared extras; any additional implicit
#               read surfaces must be documented + covered by that driver's receipts — the core does NOT establish
#               read exclusivity (unlike WRITE scope above, which IS the load-bearing boundary).
#   EVIDENCE    the scope guarantee must be receipt-backed by that driver's OWN live probes (in-scope artifact
#               CREATED / out-of-scope write ABSENT, per worker shape) before the driver may carry the loop.
#   NON-INTERFERENCE  must not write ~/.claude-class protected operator surfaces, and must not export a
#               credential-mode-changing env var (the CLAUDE_CONFIG_DIR keychain lesson — flips creds → "not logged in").
#
# Claude adapter (below): DEFAULT permission mode (no bypass); path-scoped --settings <profile>; --add-dir for reads;
# --tools availability + --disallowedTools denylist as a second layer. Per-worker deltas arrive as args.
EX_PROFILE=97
worker_spawn() {
  local worker="$1" model="$2" effort="$3" tools="$4" disallowed="$5"; shift 5
  local prof; prof="$(worker_profile "$worker")" || { log "$worker: permission profile missing or TAMPERED (${PROFILES_DIR#$HOME/}) — refusing to spawn (loopctl reprofile)"; return $EX_PROFILE; }
  local dirs d; dirs=(--add-dir "$LOOP_HOME"); for d in "$@"; do dirs+=(--add-dir "$d"); done
  # shellcheck disable=SC2086  # $disallowed is an intentional space-separated multi-arg list
  claude -p --model "$model" --effort "$effort" --settings "$prof" "${dirs[@]}" \
    --no-session-persistence --output-format json --tools "$tools" \
    --disallowedTools $disallowed
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
  local holder="${1:-?}" lock="$STATE_DIR/store.lock" epoch old pid age now
  mkdir -p "$STATE_DIR" 2>/dev/null; now="$(date +%s)"
  if mkdir "$lock" 2>/dev/null; then printf '%s %s %s\n' "$holder" "$$" "$now" > "$lock/owner" 2>/dev/null; return 0; fi
  epoch="$(awk '{print $3}' "$lock/owner" 2>/dev/null)"; old="$(awk '{print $1}' "$lock/owner" 2>/dev/null)"
  pid="$(awk '{print $2}' "$lock/owner" 2>/dev/null)"
  # FAST PATH (dead-pid steal, #16 delta 6): owner pid is a valid number and NOT alive → holder crashed, reclaim
  # now instead of waiting out STALE_LOCK_SECS. kill -0 is process-liveness, not wall-clock. pid-reuse residual
  # (a recycled pid that happens to be alive) just falls back to the epoch stale-steal below — safe.
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) if ! kill -0 "$pid" 2>/dev/null; then
         rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 1
         printf '%s %s %s\n' "$holder" "$$" "$now" > "$lock/owner" 2>/dev/null
         log "store-lock: $holder stole dead-pid lock (pid $pid gone, was '${old:-?}')"; return 0
       fi;;
  esac
  case "$epoch" in ''|*[!0-9]*) return 1;; esac          # no/garbled owner → assume fresh, don't steal
  age=$(( now - epoch )); [ "$age" -gt "$STALE_LOCK_SECS" ] || return 1
  rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 1
  printf '%s %s %s\n' "$holder" "$$" "$now" > "$lock/owner" 2>/dev/null
  log "store-lock: $holder stole stale lock (age ${age}s, was '${old:-?}')"; return 0
}
# Bounded-wait acquire — for materialize, where the reviewer ALREADY spent (~$0.43): don't drop the proposal on
# a transient garden/miner overlap, retry a few times then give up (caller must treat give-up as deferred, not
# success → no watermark advance). sleep is a delay, not a wall-clock decision-input (no-mtime rail intact).
acquire_store_lock_wait() {  # $1=holder $2=tries(default 3) $3=sleep-secs(default 5)
  local holder="${1:-?}" tries="${2:-3}" nap="${3:-5}" i
  for ((i=0; i<tries; i++)); do
    acquire_store_lock "$holder" && return 0
    [ $((i+1)) -lt "$tries" ] && sleep "$nap"
  done
  return 1
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

# (loop_manifest + manifest_changed_paths DELETED #23 — the whole-guarded-dirs manifest + before/after diff drove the
#  #16 in-window mirror/restore guard, now superseded by platform-enforced permissions + the scoped zone_fingerprint
#  tripwire above. memory-global is no longer manifest-watched: peer traffic there is expected, reconciled by ingress.)

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
