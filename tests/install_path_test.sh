#!/usr/bin/env bash
# Install-path contract: after `claude-loop install` into a temp CLAUDE_CONFIG_DIR, every file the RUNTIME
# dereferences must exist, lib.sh must source with no missing-file errors, and merge_hooks must register the
# gate-runner events + drop the absorbed on-shadow.sh. The generic guard against "shipped code references a
# file place() never installs" — the class that bit gates.tsv and tags.sh. Public-safe (no private data).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
rc=0; ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

# seed a stale pre-absorption on-shadow.sh hook → proves merge_hooks REMOVES it on upgrade (not just "fresh didn't add it")
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash %s/loop/hooks/on-shadow.sh"}]}]}}' "$tmp" > "$tmp/settings.json"
CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL  claude-loop install errored"; exit 1; }
L="$tmp/loop"
for f in gates.tsv tags.sh POLICY.md config.sh lib.sh bin/gate-runner.sh bin/shadow_score.py bin/build_index.py \
         bin/materialize.sh bin/garden.sh bin/review.sh hooks/on-precompact.sh prompts/review.md prompts/garden.md; do
  ok "$([ -e "$L/$f" ] && echo yes || echo no)" yes "installed: $f"
done
# lib.sh sources every file it references (a missing sourced file like tags.sh prints to stderr)
err="$(CLAUDE_CONFIG_DIR="$tmp" bash -c ". \"$L/lib.sh\"" 2>&1 >/dev/null)"
ok "$([ -z "$err" ] && echo clean || printf 'stderr:%s' "$err")" clean "lib.sh sources with no missing-file errors"
# merge_hooks wired the injection engine and dropped the absorbed hook
s="$tmp/settings.json"
ok "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command]|map(select(contains("gate-runner.sh prompt-submit")))|length' "$s" 2>/dev/null)" 1 "hook: UserPromptSubmit → gate-runner prompt-submit"
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|map(select(contains("gate-runner.sh subagent-spawn")))|length' "$s" 2>/dev/null)" 1 "hook: PreToolUse → gate-runner subagent-spawn"
ok "$(jq -r '[.hooks.PreCompact[]?.hooks[]?.command]|map(select(contains("on-precompact.sh")))|length' "$s" 2>/dev/null)" 1 "hook: PreCompact → on-precompact"
ok "$(jq -r '[.hooks[]?[]?.hooks[]?.command]|map(select(contains("on-shadow.sh")))|length' "$s" 2>/dev/null)" 0 "absorbed on-shadow.sh not registered"
exit "$rc"
