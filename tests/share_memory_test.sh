#!/usr/bin/env bash
# loopctl share-memory: per-home adapter auto-detection — codex (config.toml+auth.json) gets a read-only
# memory-pointer AGENTS.md (idempotent, preserves other content, absolute path, ~ expanded); claude
# (settings.json) is skipped (native auto-load covers it); the loop's own CLAUDE_HOME is NEVER a target
# even if it fingerprints as one; unknown homes are skipped. Temp homes (HOME overridden for ~); nothing live.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop"
loopctl="$root/loop/bin/loopctl"
rc=0; ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
cx="$tmp/cx"; cl="$tmp/cl"; uk="$tmp/uk"; mkdir -p "$cx" "$cl" "$uk"
touch "$cx/config.toml" "$cx/auth.json"; printf 'pre-existing\n' > "$cx/AGENTS.md"   # codex home, w/ prior content
touch "$cl/settings.json"                                                            # claude home
touch "$tmp/config.toml" "$tmp/auth.json"                                            # host ($tmp=CLAUDE_HOME) LOOKS like codex...
printf 'LOOP_ENABLED=1\nSHARE_MEMORY_HOMES="%s:%s:%s:%s"\n' "$cx" "$cl" "$uk" "$tmp" > "$tmp/loop/config.local.sh"

out="$(bash "$loopctl" share-memory 2>&1)"
ok "$(grep -c 'memory-global BEGIN' "$cx/AGENTS.md")" 1 "codex home (config.toml+auth.json) → pointer written"
grep -q 'pre-existing' "$cx/AGENTS.md"; ok "$?" 0 "codex home: pre-existing AGENTS.md preserved"
grep -qF "$LOOP_HOME/memory-global/MEMORY.md" "$cx/AGENTS.md"; ok "$?" 0 "codex home: absolute MEMORY.md path"
ok "$([ -f "$cl/AGENTS.md" ] && echo yes || echo no)" no "claude home (settings.json) → skipped (no AGENTS.md)"
printf '%s' "$out" | grep -qi 'native auto-load'; ok "$?" 0 "claude home → 'native auto-load' skip reason"
ok "$([ -f "$uk/AGENTS.md" ] && echo yes || echo no)" no "unknown home → skipped"
ok "$([ -f "$tmp/AGENTS.md" ] && echo yes || echo no)" no "host CLAUDE_HOME → never a target (even fingerprinting as codex)"

bash "$loopctl" share-memory >/dev/null 2>&1
ok "$(grep -c 'memory-global BEGIN' "$cx/AGENTS.md")" 1 "idempotent: codex block not duplicated on re-run"

printf 'LOOP_ENABLED=1\nSHARE_MEMORY_HOMES="~/ctilde"\n' > "$tmp/loop/config.local.sh"
mkdir -p "$tmp/ctilde"; touch "$tmp/ctilde/config.toml" "$tmp/ctilde/auth.json"
HOME="$tmp" bash "$loopctl" share-memory >/dev/null 2>&1
ok "$([ -f "$tmp/ctilde/AGENTS.md" ] && echo yes || echo no)" yes "leading ~ expanded (codex home)"

# explicit home arg overrides the config (one-off)
printf 'LOOP_ENABLED=1\nSHARE_MEMORY_HOMES=""\n' > "$tmp/loop/config.local.sh"
argh="$tmp/argcx"; mkdir -p "$argh"; touch "$argh/config.toml" "$argh/auth.json"
bash "$loopctl" share-memory "$argh" >/dev/null 2>&1
ok "$([ -f "$argh/AGENTS.md" ] && echo yes || echo no)" yes "explicit home arg → surfaced (overrides config)"

# no homes given + none configured → no-op with usage (no implicit ~/.codex default)
printf 'LOOP_ENABLED=1\nSHARE_MEMORY_HOMES=""\n' > "$tmp/loop/config.local.sh"
noop="$(bash "$loopctl" share-memory 2>&1)"
printf '%s' "$noop" | grep -qi 'no homes given'; ok "$?" 0 "no homes + no config → usage, no implicit default"

exit "$rc"
