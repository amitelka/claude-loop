#!/usr/bin/env bash
# recall-probe.sh: runs probe prompts through the lexical retriever vs a MEMORY.md index and reports
# hits@1/hits@3. Minimal regression guard against a temp index; nothing live.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/bin" "$tmp/memory-global"
cp "$root/loop/bin/shadow_score.py" "$tmp/loop/bin/"   # recall-probe resolves it via $LOOP_DIR/bin
cat > "$tmp/memory-global/MEMORY.md" <<'EOF'
# Memory Index
- [macOS dev gotchas](macos-dev-env-gotchas.md) — Apple-Silicon: pyenv dyld hang, BSD sed, Docker Desktop
- [LVM lv_attr open flag](lvm-lv-attr-open-flag.md) — lv_attr idx 5 = device-open; avoids lvremove stall
EOF
printf 'my pyenv dyld hang on macos\tmacos-dev-env-gotchas\nlvremove stall held volume\tlvm-lv-attr-open-flag\n' > "$tmp/probes.tsv"
rc=0
out="$(LOOP_REVIEWER=1 bash "$root/loop/bin/recall-probe.sh" "$tmp/probes.tsv" 2>&1)"
if printf '%s' "$out" | grep -q 'hits@1 2/2'; then echo "  ok    recall-probe reports hits@1 2/2 on matching probes"
else echo "  FAIL  expected 'hits@1 2/2' — got:"; printf '%s\n' "$out" | sed 's/^/      /'; rc=1; fi
exit "$rc"
