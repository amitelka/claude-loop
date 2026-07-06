#!/usr/bin/env bash
# #23 `claude-loop migrate` — relocate a pre-relocation install (~/.claude/loop + ~/.claude/memory-global) to
# LOOP_HOME, resumably. Covers: refuse-if-enabled, validate-BEFORE-move (store stays canonical on failure),
# mv-keeps-git-history, carry state/config/.env/pending, settings repoint (hooks + autoMemoryDirectory), EXEC-ONLY
# shim, idempotency, and resume-after-validate-failure. Sandboxed (non-default CLAUDE_HOME → launchd path gated off).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
CL="$repo/claude-loop"
root="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$root"' EXIT
case "$root" in "$HOME"|"$HOME/.claude"*) echo "  FATAL preflight: sandbox '$root' is a real home — ABORT"; exit 99;; esac
P=0; F=0; ok(){ P=$((P+1)); }; no(){ F=$((F+1)); echo "  FAIL: $1"; }

build_old() {   # $1 = fixture root ; a pre-#23 install (old machinery stub + a VALID git store)
  local R="$1" CH="$1/.claude" OL="$1/.claude/loop" OM="$1/.claude/memory-global"
  rm -rf "$R"; mkdir -p "$OL/bin" "$OL/hooks" "$OL/state" "$OL/pending/memories" "$OL/archive" "$CH/skills"
  printf 'LOOP_ENABLED=0\nLOOP_MODE=dry-run\n' > "$OL/config.local.sh"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-test\n' > "$OL/.env"
  echo 'watermark-state' > "$OL/state/somesession.line"
  echo 'a pending memory' > "$OL/pending/memories/p1.md"
  echo '{}' > "$CH/settings.json"
  git init -q "$OM"
  ( cd "$OM"
    printf -- '- [Test One](test-one.md) — a hot memory\n' > MEMORY.md
    printf -- '- [Test Two](test-two.md) — a cold memory\n' > ARCHIVE.md
    printf -- '---\nname: test-one\n---\nhot body\n' > test-one.md
    printf -- '---\nname: test-two\n---\ncold body\n' > test-two.md
    git add -A && git -c user.email=t@t -c user.name=t commit -qm "seed store" ) >/dev/null 2>&1
}
mig(){ CLAUDE_CONFIG_DIR="$1/.claude" LOOP_HOME="$1/.claude-loop" bash "$CL" migrate 2>&1; }

# A: refuse-if-enabled
R="$root/A"; build_old "$R"; printf 'LOOP_ENABLED=1\n' > "$R/.claude/loop/config.local.sh"
out="$(mig "$R")"; rc=$?
{ echo "$out"|grep -q "refuse:" && [ "$rc" -ne 0 ]; } && ok || no "enabled loop not refused (rc=$rc)"
[ -d "$R/.claude/memory-global" ] && ok || no "store moved despite refuse"

# B: full migration
R="$root/B"; build_old "$R"; NL="$R/.claude-loop"
seed_commit="$(git -C "$R/.claude/memory-global" rev-parse HEAD)"
out="$(mig "$R")"; rc=$?
[ "$rc" -eq 0 ] && ok || no "migrate rc=$rc — $(echo "$out"|tail -2|tr '\n' ' ')"
[ ! -d "$R/.claude/memory-global" ] && ok || no "old store still present (not moved)"
[ -e "$NL/memory-global/.git" ] && ok || no "new store missing .git"
[ "$(git -C "$NL/memory-global" rev-parse HEAD 2>/dev/null)" = "$seed_commit" ] && ok || no "git history lost"
[ -f "$NL/config.local.sh" ] && ok || no "config.local.sh not carried"
[ -f "$NL/.env" ] && ok || no ".env not carried"
[ -f "$NL/state/somesession.line" ] && ok || no "state/ not carried"
[ -f "$NL/pending/memories/p1.md" ] && ok || no "pending/ not carried"
[ "$(jq -r '.autoMemoryDirectory' "$R/.claude/settings.json" 2>/dev/null)" = "$NL/memory-global" ] && ok || no "autoMemoryDirectory not repointed"
jq -e '.hooks.Stop[0].hooks[0].command | contains("'"$NL"'/hooks")' "$R/.claude/settings.json" >/dev/null 2>&1 && ok || no "Stop hook not repointed"
[ -f "$NL/state/mem-index.json" ] && ok || no "mem-index not rebuilt"
shim="$R/.claude/loop/hooks/on-stop.sh"
{ [ -f "$shim" ] && grep -q "^exec " "$shim" && ! grep -qE '\bconfig\.sh|\blib\.sh|^\. ' "$shim"; } && ok || no "shim not EXEC-ONLY: $(cat "$shim" 2>/dev/null)"
grep -q "$NL/hooks/on-stop.sh" "$shim" 2>/dev/null && ok || no "shim target wrong"
[ ! -e "$NL/state/migrate.phase" ] && ok || no "marker not cleared on completion"

# C: idempotency
out="$(mig "$R")"; rc=$?
{ echo "$out"|grep -q "already migrated" && [ "$rc" -eq 0 ]; } && ok || no "re-run not idempotent (rc=$rc)"
[ "$(git -C "$NL/memory-global" rev-parse HEAD)" = "$seed_commit" ] && ok || no "re-run mutated store"

# D: resume after phase-3 validate failure (validate-BEFORE-move → store stays at old on failure)
R="$root/D"; build_old "$R"; NL="$R/.claude-loop"
rm -f "$R/.claude/memory-global/ARCHIVE.md"      # corrupt → validate_store fails
out="$(mig "$R")"; rc=$?
{ echo "$out"|grep -q "FAILS validate_store" && [ "$rc" -ne 0 ]; } && ok || no "validate gate did not block (rc=$rc)"
[ "$(cat "$NL/state/migrate.phase" 2>/dev/null)" = "2" ] && ok || no "marker not left at phase 2"
[ -e "$R/.claude/memory-global/.git" ] && ok || no "store moved despite validate failure (should stay at old)"
[ "$(jq -r '.autoMemoryDirectory // "unset"' "$R/.claude/settings.json")" = "unset" ] && ok || no "settings repointed despite invalid store"
printf -- '- [Test Two](test-two.md) — a cold memory\n' > "$R/.claude/memory-global/ARCHIVE.md"   # fix at OLD home
out="$(mig "$R")"; rc=$?
[ "$rc" -eq 0 ] && ok || no "resume did not complete (rc=$rc)"
[ ! -e "$NL/state/migrate.phase" ] && ok || no "marker not cleared after resume"

echo "  migrate: $P passed, $F failed"
[ "$F" -eq 0 ]