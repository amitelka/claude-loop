#!/usr/bin/env bash
# loopctl codex-surface: writes/refreshes a read-only memory-pointer block in each CODEX_HOMES dir's
# AGENTS.md (:-separated, leading ~ expanded), idempotent, preserving other content; defaults to
# ~/.codex when CODEX_HOMES is unset. Temp homes (HOME overridden for the ~ cases); nothing live.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop"
loopctl="$root/loop/bin/loopctl"; h1="$tmp/ch"; h2="$tmp/chp"
rc=0; ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

# --- two homes, :-separated; one has pre-existing content ---
printf 'LOOP_ENABLED=1\nCODEX_HOMES="%s:%s"\n' "$h1" "$h2" > "$tmp/loop/config.local.sh"
mkdir -p "$h1"; printf 'my own codex guidance\n' > "$h1/AGENTS.md"
bash "$loopctl" codex-surface >/dev/null 2>&1
ok "$(grep -c 'memory-global BEGIN' "$h1/AGENTS.md")" 1 "home1: pointer block written"
ok "$(grep -c 'memory-global BEGIN' "$h2/AGENTS.md")" 1 "home2 (:-separated): pointer block written"
grep -q 'my own codex guidance' "$h1/AGENTS.md"; ok "$?" 0 "pre-existing AGENTS.md content preserved"
grep -qF "$tmp/memory-global/MEMORY.md" "$h1/AGENTS.md"; ok "$?" 0 "absolute MEMORY.md path (Codex resolves bodies)"
grep -qi 'do not write' "$h1/AGENTS.md"; ok "$?" 0 "read-only instruction present"

# --- idempotent ---
bash "$loopctl" codex-surface >/dev/null 2>&1
ok "$(grep -c 'memory-global BEGIN' "$h1/AGENTS.md")" 1 "idempotent: block not duplicated on re-run"
grep -q 'my own codex guidance' "$h1/AGENTS.md"; ok "$?" 0 "content still preserved after re-run"

# --- leading ~ expands (HOME overridden to tmp) ---
printf 'LOOP_ENABLED=1\nCODEX_HOMES="~/ctilde"\n' > "$tmp/loop/config.local.sh"
HOME="$tmp" bash "$loopctl" codex-surface >/dev/null 2>&1
[ -f "$tmp/ctilde/AGENTS.md" ]; ok "$?" 0 "leading ~ expanded to \$HOME"

# --- unset CODEX_HOMES + ~/.codex exists → defaults there ---
printf 'LOOP_ENABLED=1\n' > "$tmp/loop/config.local.sh"; mkdir -p "$tmp/.codex"
HOME="$tmp" bash "$loopctl" codex-surface >/dev/null 2>&1
[ -f "$tmp/.codex/AGENTS.md" ]; ok "$?" 0 "unset CODEX_HOMES + ~/.codex present → defaults to ~/.codex"

exit "$rc"
