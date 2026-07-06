#!/usr/bin/env bash
# #23 relocation contract + skill clobber-guard. `install` places machinery + STORE at LOOP_HOME (out of the
# protected ~/.claude); settings hooks + autoMemoryDirectory point at LOOP_HOME; skills stay at CLAUDE_HOME/skills
# (discovery dir). The skills clobber-guard (#9): a re-install over a hand-edited installed skill preserves the
# edit as .bak before overwriting; an UNEDITED skill is overwritten silently.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export LOOP_HOME="$tmp/.claude-loop"   # DISTINCT from CLAUDE_HOME ($tmp) — this test proves the separation
rc=0; ok(){ if [ "$1" = "$2" ]; then :; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
NL="$LOOP_HOME"

echo "── install relocation contract ──"
CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL install"; exit 1; }
ok "$([ -f "$NL/lib.sh" ]&&echo y||echo n)" y "machinery at LOOP_HOME (lib.sh)"
ok "$([ -d "$NL/bin" ]&&echo y||echo n)" y "machinery at LOOP_HOME (bin/)"
ok "$([ -d "$NL/memory-global" ]&&echo y||echo n)" y "store dir at LOOP_HOME/memory-global"
ok "$([ -d "$NL/state/profiles" ]&&echo y||echo n)" y "profiles materialized under LOOP_HOME/state"
ok "$(jq -r '.autoMemoryDirectory' "$tmp/settings.json" 2>/dev/null)" "$NL/memory-global" "settings.autoMemoryDirectory → LOOP_HOME/memory-global"
ok "$(jq -e '.hooks.Stop[0].hooks[0].command | contains("'"$NL"'/hooks")' "$tmp/settings.json" >/dev/null 2>&1 && echo y||echo n)" y "settings Stop hook → LOOP_HOME/hooks"
ok "$([ -d "$tmp/skills/review-memories" ]&&echo y||echo n)" y "skills stay at CLAUDE_HOME/skills (discovery dir)"
ok "$([ -e "$tmp/loop" ]&&echo present||echo absent)" absent "no machinery at the old CLAUDE_HOME/loop path (store lives OUT of ~/.claude)"

echo "── skill clobber-guard (#9) via re-install ──"
# UNEDITED re-install → silent overwrite, no .bak, no warn
out="$(CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install 2>&1)"
ok "$(printf '%s' "$out" | grep -c 'locally modified' | tr -d ' ')" 0 "unedited re-install → NO clobber warning"
ok "$([ -e "$tmp/skills/review-memories.bak" ]&&echo present||echo absent)" absent "unedited re-install → NO .bak"
# LOCAL EDIT then re-install → .bak preserves the edit, repo version reinstalled
printf '\nLOCAL OPERATOR EDIT\n' >> "$tmp/skills/review-memories/SKILL.md"
out="$(CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install 2>&1)"
ok "$(printf '%s' "$out" | grep -c 'locally modified' | tr -d ' ' | grep -qv '^0$' && echo warned||echo silent)" warned "edited re-install → clobber WARNING emitted"
ok "$([ -d "$tmp/skills/review-memories.bak" ] && grep -q 'LOCAL OPERATOR EDIT' "$tmp/skills/review-memories.bak/SKILL.md" && echo preserved||echo lost)" preserved "edited skill preserved in .bak"
ok "$(grep -q 'LOCAL OPERATOR EDIT' "$tmp/skills/review-memories/SKILL.md" && echo stale||echo repo)" repo "installed skill re-synced to repo (edit not carried forward)"

echo "── P1: symlinks under installed skills are flagged by doctor (must be copies, tripwire-visible) ──"
printf 'LOOP_ENABLED=1\n' > "$NL/config.local.sh"
dout="$(CLAUDE_CONFIG_DIR="$tmp" bash "$NL/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"installed skills are real files"*) ok yes yes;; *) ok no yes "doctor: real-skills row present when no symlink";; esac
real_target="$tmp/ext-skill"; mkdir -p "$real_target"; printf 'SKILL\n' > "$real_target/SKILL.md"
# (a) a top-level symlinked skill DIR → flagged
rm -rf "$tmp/skills/review-skills"; ln -s "$real_target" "$tmp/skills/review-skills"
dout="$(CLAUDE_CONFIG_DIR="$tmp" bash "$NL/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"symlink(s) under installed skills"*) ok yes yes;; *) ok no yes "doctor: top-level symlinked skill FLAGGED";; esac
# (b) a NESTED symlink inside a real skill dir → flagged too (recursive check, strictly better than top-level-only)
rm -rf "$tmp/skills/review-skills"; cp -R "$repo/skills/review-skills" "$tmp/skills/review-skills"
ln -s "$real_target/SKILL.md" "$tmp/skills/review-skills/sneaky-link.md"
dout="$(CLAUDE_CONFIG_DIR="$tmp" bash "$NL/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"symlink(s) under installed skills"*) ok yes yes;; *) ok no yes "doctor: NESTED symlink under a skill FLAGGED (recursive)";; esac

echo "  (relocation: $( [ "$rc" = 0 ] && echo ALL GREEN || echo has failures ))"
exit "$rc"