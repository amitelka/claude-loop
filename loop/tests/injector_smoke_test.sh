#!/usr/bin/env bash
# Injector smoke test: fixture query → gate-runner injects under a LIVE gate; respects per-session dedup, stays
# silent in shadow, obeys the kill switch, AND (subagent-spawn) rewrites the subagent's prompt via updatedInput
# while PRESERVING the other Task fields. Tests ENGINE MECHANICS end-to-end on a hermetic temp loop — the tiny
# fixture scores differently from the real corpus, so it zeroes the tested rows' thresholds (the calibrated
# operating point is exercised by probes_ci_test.sh). Nothing live.
set -uo pipefail
unset LOOP_REVIEWER
root="$(cd "$(dirname "$0")/.." && pwd)"          # repo/loop
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"
mkdir -p "$tmp/loop/bin" "$tmp/loop/state" "$tmp/memory-global"
cp "$root/lib.sh" "$root/tags.sh" "$root/config.sh" "$root/gates.tsv" "$tmp/loop/"
cp "$root/bin/shadow_score.py" "$root/bin/gate-runner.sh" "$root/bin/build_index.py" "$tmp/loop/bin/"
cat > "$tmp/memory-global/MEMORY.md" <<'EOF'
# Memory Index

- [macOS dev gotchas](macos-dev-env-gotchas.md) — Apple-Silicon PDF PATH, BSD sed, pyenv dyld hang
EOF
cat > "$tmp/memory-global/ARCHIVE.md" <<'EOF'
# Memory Archive (cold tier)

- [LVM lv_attr open flag](lvm-lv-attr-open-flag.md) — lvremove stalling ~5s logical volume held open lv_attr device-open avoids lvremove stall
EOF
# body files carry YAML frontmatter like production memories, so the index exercises full-file (frontmatter+body) tokenization
cat > "$tmp/memory-global/lvm-lv-attr-open-flag.md" <<'EOF'
---
name: lvm-lv-attr-open-flag
description: lvremove stalling ~5s logical volume held open lv_attr device-open
metadata:
  type: reference
---
lvremove stalls ~5 seconds when the logical volume is held open; lv_attr index 5 flags device-open.
EOF
cat > "$tmp/memory-global/macos-dev-env-gotchas.md" <<'EOF'
---
name: macos-dev-env-gotchas
description: Apple-Silicon PDF PATH, BSD sed, pyenv dyld hang
metadata:
  type: reference
---
macOS Apple-Silicon dev gotchas: pyenv dyld hang, BSD sed, PDF PATH.
EOF
python3 "$tmp/loop/bin/build_index.py" "$tmp/memory-global" "$tmp/loop/state/mem-index.json" >/dev/null

# mechanics test → zero the tested rows' thresholds (fixture scores ≠ real-corpus operating point)
awk -F'\t' 'BEGIN{OFS="\t"} /^(prompt-submit|subagent-spawn)\t/{$5="0"} {print}' "$tmp/loop/gates.tsv" > "$tmp/g" && mv "$tmp/g" "$tmp/loop/gates.tsv"
setmode(){ ROW="$1" NEW="$2" perl -0pi -e 's/^($ENV{ROW}\t.*\t)(shadow|live)(\t[a-z]+)$/$1$ENV{NEW}$3/m' "$tmp/loop/gates.tsv"; }
rc=0; ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
run(){ printf '%s' "$2" | bash "$tmp/loop/bin/gate-runner.sh" "$1"; }
printf 'MEASUREMENT_ENABLED=1\nLOOP_ENABLED=1\nLOOP_MODE=active\n' > "$tmp/loop/config.local.sh"

# ── prompt-submit: context inject → additionalContext (main conversation) ──
setmode prompt-submit live
F='{"prompt":"lvremove is stalling ~5 seconds, is the logical volume held open","session_id":"s1"}'
out="$(run prompt-submit "$F")"
printf '%s' "$out" | grep -q additionalContext; ok "$?" 0 "live prompt-submit emits additionalContext"
printf '%s' "$out" | grep -q 'lvm-lv-attr-open-flag'; ok "$?" 0 "injects the lvm pointer for the lvremove prompt"
out2="$(run prompt-submit "$F")"
ok "$([ -z "$out2" ] && echo empty || echo nonempty)" empty "dedup: same slug not re-injected in-session"
ok "$([ -s "$tmp/loop/state/measure/shadow.jsonl" ] && echo yes || echo no)" yes "shadow.jsonl logged the scored event"

# malicious session_id must not escape the inject dir (path-traversal guard — sid is untrusted hook input)
run prompt-submit '{"prompt":"lvremove is stalling, is the logical volume held open","session_id":"../evil"}' >/dev/null
ok "$([ -e "$tmp/loop/state/evil.txt" ] && echo escaped || echo safe)" safe "malicious sid does NOT escape inject/ (no state/evil.txt)"
ok "$(find "$tmp/loop/state/inject/" -name '*evil*' 2>/dev/null | wc -l | tr -d ' ')" 1 "sanitized sid landed inside inject/ (as ..evil.txt)"

# ── subagent-spawn: prompt inject → updatedInput.prompt, other Task fields survive ──
setmode subagent-spawn live
S='{"tool_name":"Task","session_id":"s2","tool_input":{"prompt":"lvremove is stalling, is the logical volume held open","subagent_type":"general-purpose","description":"debug lvm"}}'
sout="$(run subagent-spawn "$S")"
printf '%s' "$sout" | grep -q updatedInput; ok "$?" 0 "subagent-spawn emits updatedInput"
printf '%s' "$sout" | grep -q additionalContext; ok "$?" 1 "subagent-spawn does NOT emit additionalContext"
ok "$(printf '%s' "$sout" | jq -r '.hookSpecificOutput.updatedInput.prompt' 2>/dev/null | grep -c 'lvm-lv-attr-open-flag')" 1 "pointer spliced into the subagent prompt"
ok "$(printf '%s' "$sout" | jq -r '.hookSpecificOutput.updatedInput.subagent_type' 2>/dev/null)" general-purpose "subagent_type survives the rewrite"
ok "$(printf '%s' "$sout" | jq -r '.hookSpecificOutput.updatedInput.description' 2>/dev/null)" "debug lvm" "description survives the rewrite"
ok "$(grep -c 'lvm-lv-attr-open-flag' "$tmp/loop/state/inject/s2.txt" 2>/dev/null)" 1 "dedup marks the slug on the prompt-inject path"

# ── per-candidate threshold: a deduped top1 must NOT carry sub-threshold tail candidates (codex MEDIUM) ──
DQ='macos pyenv dyld lvremove logical volume held open'   # hits BOTH memories → 2 candidates, distinct scores
sc="$(printf '%s' "$DQ" | MEM_INDEX_JSON="$tmp/loop/state/mem-index.json" TOPK=3 /usr/bin/python3 "$tmp/loop/bin/shadow_score.py" 2>/dev/null)"
t1s="$(printf '%s' "$sc" | jq -r '.top[0].slug')"; t1v="$(printf '%s' "$sc" | jq -r '.top[0].score')"; t2s="$(printf '%s' "$sc" | jq -r '.top[1].slug // "NONE"')"
awk -F'\t' -v T="$t1v" 'BEGIN{OFS="\t"} /^prompt-submit\t/{$5=T} {print}' "$tmp/loop/gates.tsv" > "$tmp/g" && mv "$tmp/g" "$tmp/loop/gates.tsv"
DF="$(jq -cn --arg p "$DQ" '{prompt:$p,session_id:"sT"}')"
o1="$(run prompt-submit "$DF")"
ok "$(printf '%s' "$o1" | grep -c "$t1s")" 1 "per-candidate: top1 (clears threshold) injects"
ok "$(printf '%s' "$o1" | grep -c "$t2s")" 0 "per-candidate: sub-threshold top2 does NOT ride in on top1"
o2="$(run prompt-submit "$DF")"
ok "$([ -z "$o2" ] && echo empty || echo nonempty)" empty "per-candidate: deduped top1 + sub-threshold top2 → nothing"

# ── shadow mode: logs, never injects ──
setmode prompt-submit shadow
outs="$(run prompt-submit '{"prompt":"lvremove is stalling, LV held open","session_id":"s3"}')"
ok "$([ -z "$outs" ] && echo empty || echo nonempty)" empty "shadow mode: logs, never injects"

# ── kill switch ──
printf 'MEASUREMENT_ENABLED=0\nLOOP_ENABLED=1\n' > "$tmp/loop/config.local.sh"; setmode prompt-submit live
outk="$(run prompt-submit '{"prompt":"lvremove is stalling, LV held open","session_id":"s4"}')"
ok "$([ -z "$outk" ] && echo empty || echo nonempty)" empty "kill switch (MEASUREMENT_ENABLED=0) → nothing"
exit "$rc"
