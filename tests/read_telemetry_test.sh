#!/usr/bin/env bash
# on-read.sh: logs memory-global reads with prompt_id + agent_id (subagent), skips non-memory reads,
# no-ops when measurement is off. Feeds sample PostToolUse stdin; nothing live. Toggles via a temp
# config.local.sh (config.sh sets LOOP_ENABLED/MEASUREMENT_ENABLED unconditionally, so env won't stick).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state" "$LOOP_HOME/memory-global"
hook="$root/loop/hooks/on-read.sh"; md="$LOOP_HOME/memory-global"; reads="$tmp/loop/state/measure/reads.jsonl"
rc=0
ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
run() { printf 'LOOP_ENABLED=1\nMEASUREMENT_ENABLED=%s\n' "${2:-1}" > "$tmp/loop/config.local.sh"; printf '%s' "$1" | bash "$hook"; }
lines() { [ -f "$reads" ] && wc -l < "$reads" | tr -d ' ' || echo 0; }

run "$(jq -cn --arg p "$md/foo.md" '{session_id:"s1",prompt_id:"p1",tool_input:{file_path:$p}}')"
ok "$(jq -r .path "$reads" 2>/dev/null | tail -1)" "foo.md" "memory read → logged (path)"
ok "$(jq -r .prompt "$reads" 2>/dev/null | tail -1)" "p1" "records prompt_id (join key)"

run "$(jq -cn --arg p "$md/bar.md" '{session_id:"s1",prompt_id:"p1",agent_id:"ag9",tool_input:{file_path:$p}}')"
ok "$(jq -r .agent "$reads" 2>/dev/null | tail -1)" "ag9" "subagent read → agent_id captured"

n="$(lines)"
run "$(jq -cn '{session_id:"s1",prompt_id:"p1",tool_input:{file_path:"/etc/hosts"}}')"
ok "$(lines)" "$n" "non-memory read → not logged"

run "$(jq -cn --arg p "$md/baz.md" '{session_id:"s1",prompt_id:"p1",tool_input:{file_path:$p}}')" 0
ok "$(lines)" "$n" "measurement off → not logged"

exit "$rc"
