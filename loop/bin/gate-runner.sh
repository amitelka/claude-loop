#!/usr/bin/env bash
# THE injection engine. One code path for every retrieval channel; loop/gates.tsv decides which tool events get
# scored + injected, per-row {event, matcher, field(jq), threshold, mode}. Pipeline: score → log to shadow.jsonl
# (ALWAYS — the log stage; a live row still logs) → if mode=live AND top≥threshold AND not already injected this
# session, inject the top-k pointer lines (hint-framed) via hookSpecificOutput.additionalContext. Absorbs the old
# on-shadow.sh. Fail-open + fast-bail throughout; gated by measure_on (MEASUREMENT_ENABLED && LOOP_ENABLED &&
# !LOOP_REVIEWER). Invoked by each hook as: gate-runner.sh <gate-name>, hook JSON on stdin.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
loop_enabled || exit 0   # kill switch: LOOP_ENABLED=0 → fully inert (measure_on also gates it; explicit + uniform)
measure_on || exit 0
gate="${1:-}"; [ -n "$gate" ] || exit 0
input="$(cat 2>/dev/null)"
row="$(grep -v '^#' "$LOOP_DIR/gates.tsv" 2>/dev/null | awk -F'\t' -v g="$gate" '$1==g{print; exit}')"
[ -n "$row" ] || exit 0
IFS=$'\t' read -r name event matcher field threshold mode inject <<<"$row"
[ "$mode" = off ] && exit 0
[ -n "$inject" ] || inject=context   # default: additionalContext (back-compat for a 6-col row)

# tool matcher (PreToolUse/PostToolUse carry .tool_name; "." = no matcher)
if [ "$matcher" != "." ]; then
  tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
  printf '%s' "$tool" | grep -qE "^($matcher)$" || exit 0
fi
query="$(printf '%s' "$input" | jq -r "$field" 2>/dev/null)"
[ -n "$query" ] && [ "$query" != null ] || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
pid="$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null)"
line="$(printf '%s' "$query" | MEM_INDEX_JSON="$STATE_DIR/mem-index.json" TOPK=3 MV="$MEASUREMENT_VERSION" \
        SID="$sid" PID="$pid" /usr/bin/python3 "$LOOP_DIR/bin/shadow_score.py" 2>/dev/null)"
[ -n "$line" ] || exit 0

# log stage (always) — tag the line with the gate name
tagged="$(printf '%s' "$line" | jq -c --arg g "$name" '. + {gate:$g}' 2>/dev/null)" || tagged="$line"
measure_append shadow "$tagged"

[ "$mode" = live ] || exit 0   # shadow rows: logged, never inject

# inject stage — early-exit if even the top candidate is below threshold
top="$(printf '%s' "$line" | jq -r '.top[0].score // 0' 2>/dev/null)"
awk "BEGIN{exit !($top >= $threshold)}" 2>/dev/null || exit 0

# per-session dedup (reset on PreCompact). Each candidate must INDIVIDUALLY clear the threshold AND not already
# be surfaced this session — otherwise a deduped high-scorer would carry sub-threshold tail candidates into injection.
ddir="$STATE_DIR/inject"; mkdir -p "$ddir" 2>/dev/null
dfile="$ddir/$(sanitize_sid "$sid").txt"; touch "$dfile" 2>/dev/null   # sid is hook input — never a raw path
ptrs=""
while IFS=$'\t' read -r s sc; do
  [ -n "$s" ] || continue
  awk "BEGIN{exit !($sc >= $threshold)}" 2>/dev/null || continue   # this candidate below threshold → skip
  grep -qxF "$s" "$dfile" 2>/dev/null && continue                   # already surfaced this session
  ln="$(grep -hF "]($s.md)" "$MEMORY_DIR/MEMORY.md" "$MEMORY_DIR/ARCHIVE.md" 2>/dev/null | head -1)"
  [ -n "$ln" ] && { ptrs="$ptrs$ln"$'\n'; echo "$s" >> "$dfile"; }
done < <(printf '%s' "$line" | jq -r '.top[] | "\(.slug)\t\(.score)"' 2>/dev/null)
[ -n "$ptrs" ] || exit 0

ctx="[loop] possibly relevant memories — read the file if it applies, ignore if not:"$'\n'"$ptrs"
if [ "$inject" = prompt ]; then
  # subagent-spawn: splice pointers into the SUBAGENT's own prompt via updatedInput. additionalContext on a
  # PreToolUse Task hook lands in the PARENT, not the subagent (empirically verified) — updatedInput replaces
  # the tool args, so the appended text becomes part of the spawned agent's actual prompt.
  ti="$(printf '%s' "$input" | jq -c --arg c "$ctx" '.tool_input | .prompt = ((.prompt // "") + "\n\n" + $c)' 2>/dev/null)" || exit 0
  jq -cn --arg e "$event" --argjson ti "$ti" '{hookSpecificOutput:{hookEventName:$e,updatedInput:$ti}}'
else
  jq -cn --arg e "$event" --arg c "$ctx" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
fi
exit 0
