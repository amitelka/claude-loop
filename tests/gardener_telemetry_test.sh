#!/usr/bin/env bash
# Gardener telemetry: garden_actions derives a deterministic {deleted|added|modified} sidecar from the
# pre→post garden git diff (MEMORY.md churn excluded); materialize logs `regret <slug>` when it re-writes
# a memory the gardener previously deleted. Temp mem-git + temp CLAUDE_CONFIG_DIR; nothing live.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"
mkdir -p "$tmp/loop/state" "$tmp/loop/log" "$tmp/loop/pending/memories" "$tmp/memory-global"
printf 'LOOP_ENABLED=1\nLOOP_MODE=active\n' > "$tmp/loop/config.local.sh"
# shellcheck source=/dev/null
. "$root/loop/lib.sh" 2>/dev/null || { echo "  FAIL  cannot source lib.sh"; exit 1; }
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
rc=0; ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

# --- garden_actions: seed a mem-git repo, snapshot, mutate (prune/add/trim + index churn), snapshot ---
printf 'keep\n' > "$MEMORY_DIR/keep-me.md"; printf 'old\n' > "$MEMORY_DIR/stale-fact.md"; : > "$MEMORY_DIR/MEMORY.md"
mem_snapshot "pre-garden" >/dev/null 2>&1; pre="$(mem_git rev-parse HEAD)"
rm "$MEMORY_DIR/stale-fact.md"                 # prune
printf 'new\n'   > "$MEMORY_DIR/fresh-fact.md" # add
printf 'keep+\n' > "$MEMORY_DIR/keep-me.md"    # trim
printf '%s\n' '- index churn' >> "$MEMORY_DIR/MEMORY.md"   # modified index — must be excluded (not an action)
mem_snapshot "post-garden" >/dev/null 2>&1
garden_actions "$pre" "$(mem_git rev-parse HEAD)"
ga="$STATE_DIR/garden-actions.jsonl"
ok "$(grep -c '"action":"deleted","slug":"stale-fact"' "$ga")" 1 "pruned memory → sidecar deleted"
ok "$(grep -c '"action":"added","slug":"fresh-fact"' "$ga")" 1 "added memory → sidecar added"
ok "$(grep -c '"action":"modified","slug":"keep-me"' "$ga")" 1 "trimmed memory → sidecar modified"
ok "$(grep -c 'MEMORY.md' "$ga")" 0 "MEMORY.md index churn excluded"

# --- regret: materialize re-writes the pruned slug → logs regret; a fresh slug does not ---
: > "$LOG"
printf '{"memories":[{"slug":"stale-fact","type":"feedback","description":"the fact returned","body":"b","why":"w","how_to_apply":"h"}]}' > "$tmp/p.json"
bash "$root/loop/bin/materialize.sh" "$tmp/p.json" testsess "$tmp" >/dev/null 2>&1
ok "$(grep -c '  regret stale-fact' "$LOG")" 1 "re-captured a gardener-pruned slug → regret logged"
: > "$LOG"
printf '{"memories":[{"slug":"brand-new","type":"feedback","description":"never pruned","body":"b","why":"w","how_to_apply":"h"}]}' > "$tmp/p.json"
bash "$root/loop/bin/materialize.sh" "$tmp/p.json" testsess "$tmp" >/dev/null 2>&1
ok "$(grep -c '  regret ' "$LOG")" 0 "never-pruned slug → no regret"

exit "$rc"
