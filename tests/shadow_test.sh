#!/usr/bin/env bash
# gate-runner (shadow mode) + shadow_score.py on the prompt-submit gate — the UserPromptSubmit path that
# absorbed on-shadow.sh: score a prompt vs the derived index, LOG the would-inject top-k + verdict INCLUDING
# misses (the re-probe denominator), inject nothing in shadow, no-op when measurement is off. Nothing live.
set -uo pipefail
unset LOOP_REVIEWER
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state" "$tmp/loop/bin" "$tmp/memory-global"
cp "$root/loop/lib.sh" "$root/loop/config.sh" "$root/loop/tags.sh" "$root/loop/gates.tsv" "$tmp/loop/"
cp "$root/loop/bin/shadow_score.py" "$root/loop/bin/gate-runner.sh" "$root/loop/bin/build_index.py" "$tmp/loop/bin/"
cat > "$tmp/memory-global/MEMORY.md" <<'EOF'
# Memory Index
- [macOS dev gotchas](macos-dev-env-gotchas.md) — Apple-Silicon: PDF PATH, BSD sed, Docker Desktop, pyenv dyld hang
- [LVM lv_attr open flag](lvm-lv-attr-open-flag.md) — lv_attr idx 5 = device-open; avoids lvremove stall
EOF
printf '# Memory Archive (cold tier)\n' > "$tmp/memory-global/ARCHIVE.md"
python3 "$tmp/loop/bin/build_index.py" "$tmp/memory-global" "$tmp/loop/state/mem-index.json" >/dev/null
shadow="$tmp/loop/state/measure/shadow.jsonl"
rc=0
ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
run() { printf 'LOOP_ENABLED=1\nMEASUREMENT_ENABLED=%s\n' "${2:-1}" > "$tmp/loop/config.local.sh"; printf '%s' "$1" | bash "$tmp/loop/bin/gate-runner.sh" prompt-submit; }
mk() { jq -cn --arg p "$1" '{prompt:$p,session_id:"s1",prompt_id:"p1"}'; }
lines() { [ -f "$shadow" ] && wc -l < "$shadow" | tr -d ' ' || echo 0; }

run "$(mk 'my pyenv dyld hang on macos build')"
ok "$(jq -r .verdict "$shadow" 2>/dev/null | tail -1)" hit "matching prompt → verdict hit"
ok "$(jq -r '.top[0].slug' "$shadow" 2>/dev/null | tail -1)" macos-dev-env-gotchas "top candidate = the right memory"

n="$(lines)"
run "$(mk 'xyzzy frobnicate quux')"
ok "$(jq -r .verdict "$shadow" 2>/dev/null | tail -1)" no-match "nonsense prompt → no-match"
ok "$(( $(lines) - n ))" 1 "miss is still logged (denominator, not skipped)"

m="$(lines)"
run "$(mk 'pyenv dyld hang')" 0
ok "$(lines)" "$m" "measurement off → nothing logged"
exit "$rc"
