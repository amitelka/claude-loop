#!/usr/bin/env bash
# Skill-usage telemetry. Wired to TWO events (a single Skill hook misses half the uses):
#   PostToolUse matcher "Skill"  → model-invoked skills (name in tool_input.skill)
#   UserPromptExpansion          → user-typed /skill   (name in command_name)
# Appends one JSONL line per invocation to state/skill-uses.jsonl (skill NAME only, no args — avoids
# logging secrets in slash-command args); `loopctl skill-stats` aggregates
# (and filters built-in commands). Best-effort + NON-BLOCKING: always exits 0, never disrupts a session.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null
cat 2>/dev/null | jq -c '
  if (.hook_event_name=="PostToolUse" and .tool_name=="Skill") then
    {ts:(now|todate), skill:(.tool_input.skill // .tool_response.commandName // ""), via:"model",
     session:(.session_id // ""), cwd:(.cwd // ""), agent:(.agent_id // "")}
  elif (.hook_event_name=="UserPromptExpansion") then
    {ts:(now|todate), skill:(.command_name // ""), via:"user",
     session:(.session_id // ""), cwd:(.cwd // ""), agent:(.agent_id // "")}
  else empty end
  | select(.skill != "")
' >> "$STATE_DIR/skill-uses.jsonl" 2>/dev/null
exit 0
