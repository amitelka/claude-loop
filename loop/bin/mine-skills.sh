#!/usr/bin/env bash
# Skill candidate-miner (1b) — MANUAL-FIRST, not scheduled. Mines memory-global + skill usage for
# reusable procedures and stages NEW skills or PATCHES to existing ones into pending/skills (human-gated
# via /review-skills; NEVER auto-installs). `mine-skills.sh --dry-run` shows candidates without staging.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1
dry=0; [ "${1:-}" = "--dry-run" ] && dry=1

SECRET='sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{24,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]'
kebab='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
yqs() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

ts="$(date '+%Y%m%dT%H%M%S')"
proposal="$LOOP_DIR/proposals/mine-skills-$ts.json"
prompt="$(cat "$LOOP_DIR/prompts/mine-skills.md")"
prompt="${prompt//'{{MEMORY_DIR}}'/$MEMORY_DIR}"
prompt="${prompt//'{{SKILLS_DIR}}'/$SKILLS_DIR}"
prompt="${prompt//'{{PENDING_SKILLS}}'/$PENDING_SKILLS}"
prompt="${prompt//'{{SKILL_USES}}'/$STATE_DIR/skill-uses.jsonl}"
prompt="${prompt//'{{PROPOSAL_FILE}}'/$proposal}"

guard_before="$(loop_manifest)"   # miner may write ONLY its proposal file (in proposals/, not fingerprinted)
log "mine-skills: start model=$GARDENER_MODEL dry=$dry"
raw="$(printf '%s' "$prompt" | claude -p \
  --model "$GARDENER_MODEL" --effort "$GARDENER_EFFORT" \
  --permission-mode bypassPermissions --add-dir "$CLAUDE_HOME" \
  --no-session-persistence --output-format json \
  --allowedTools Read Grep Glob Write 2>/dev/null)"
rc=$?
is_err="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.is_error) else (.is_error // false) end' 2>/dev/null)"
cost="$(printf '%s' "$raw" | jq -r 'if type=="array" then (map(select(.type=="result"))|last|.total_cost_usd) else empty end' 2>/dev/null)"
if [ "$rc" -ne 0 ] || [ "$is_err" = "true" ] || ! { [ -f "$proposal" ] && jq -e . "$proposal" >/dev/null 2>&1; }; then
  log "mine-skills: FAILED (rc=$rc err=$is_err) — no valid proposal"; echo "mine-skills: failed (see $LOG)"; exit 1
fi
if [ "$guard_before" != "$(loop_manifest)" ]; then
  log "mine-skills: ANOMALY — miner touched memory-global/pending/skills directly; aborting (nothing staged)"
  echo "mine-skills: anomaly — miner touched real state; aborted"; exit 1
fi

n=$(jq '.candidates|length' "$proposal" 2>/dev/null || echo 0)
echo "mine-skills: $n candidate(s)$([ "$dry" = 1 ] && printf '  [DRY-RUN — nothing staged]')  (cost=${cost:-?})"
staged=0; rej=0
for ((i=0; i<n && i<3; i++)); do
  c=$(jq -c ".candidates[$i]" "$proposal")
  action=$(printf '%s' "$c" | jq -r '.action // "new"'); case "$action" in new|patch) ;; *) action=new ;; esac
  name=$(printf '%s' "$c" | jq -r '.name // empty' | tr -cd 'a-z0-9-' | cut -c1-64)
  desc=$(printf '%s' "$c" | jq -r '.description // empty')
  [[ "$name" =~ $kebab ]] || { echo "  reject (bad name '$name')"; rej=$((rej+1)); continue; }
  [ -n "$desc" ] || { echo "  reject $name (no description)"; rej=$((rej+1)); continue; }
  if printf '%s' "$c" | grep -qiE "$SECRET"; then echo "  reject $name (secret-like)"; rej=$((rej+1)); continue; fi
  evalok=$(printf '%s' "$c" | jq -r '(((.trigger_examples//[])|length)>0) and (((.expected_tools//[])|length)>0) and (((.replay_scenario//"")|length)>0)' 2>/dev/null)
  [ "$evalok" = true ] || { echo "  reject $name (1e eval-gate: needs trigger_examples + expected_tools + replay_scenario)"; rej=$((rej+1)); continue; }

  if [ "$dry" = 1 ]; then
    echo "  [$action] $name — $desc"
    echo "      sources : $(printf '%s' "$c" | jq -r '(.source_memories // [])|join(", ")')"
    echo "      triggers: $(printf '%s' "$c" | jq -r '(.trigger_examples // [])|join(" | ")')"
    continue
  fi

  meta="$(printf '%s' "$c" | jq -r '
    "## Triggers\n" + (((.trigger_examples//[])|map("- "+.))|join("\n")) +
    "\n\n## Negative triggers\n" + (((.negative_triggers//[])|map("- "+.))|join("\n")) +
    "\n\n## Expected tools\n" + ((.expected_tools//[])|join(", ")) +
    "\n\n## Expected output\n" + (.expected_output//"") +
    "\n\n## Replay scenario\n" + (.replay_scenario//"")')"
  srcs="$(printf '%s' "$c" | jq -r '(.source_memories//[])|join(", ")')"
  why="$(printf '%s' "$c" | jq -r '.why // empty')"

  if [ "$action" = patch ]; then
    [ -f "$SKILLS_DIR/$name/SKILL.md" ] || { echo "  reject patch $name (no installed skill to patch — should be a new skill)"; rej=$((rej+1)); continue; }
    mkdir -p "$PENDING_SKILLS/$name"   # stage as a DIR so /review-skills + pending_skill_count see it
    { printf '# PATCH proposal for skill: %s\n\n%s\n\n## Proposed change\n%s\n\n%s\n' \
        "$name" "$desc" "$(printf '%s' "$c" | jq -r '.patch // empty')" "$meta"; } > "$PENDING_SKILLS/$name/PATCH.md"
    printf 'source_memories: %s\nwhy: %s\n' "$srcs" "$why" > "$PENDING_SKILLS/$name/WHY.md"
    echo "  +patch $name -> pending/skills/$name/PATCH.md"
  else
    { [ -d "$SKILLS_DIR/$name" ] || [ -d "$PENDING_SKILLS/$name" ]; } && { echo "  skip $name (exists — should be a patch)"; rej=$((rej+1)); continue; }
    mkdir -p "$PENDING_SKILLS/$name"
    when="$(printf '%s' "$c" | jq -r '.when_to_use // empty')"
    body="$(printf '%s' "$c" | jq -r '.body // empty')"
    { printf -- '---\nname: %s\ndescription: %s\nwhen_to_use: %s\nuser-invocable: true\n---\n\n%s\n\n%s\n' \
        "$name" "$(yqs "$desc")" "$(yqs "$when")" "$body" "$meta"; } > "$PENDING_SKILLS/$name/SKILL.md"
    printf 'source_memories: %s\nwhy: %s\n' "$srcs" "$why" > "$PENDING_SKILLS/$name/WHY.md"
    echo "  +skill $name -> pending/skills/$name/"
  fi
  staged=$((staged+1))
done
log "mine-skills: done candidates=$n staged=$staged rejected=$rej dry=$dry cost=${cost:-?}"
[ "$dry" = 1 ] && echo "(dry-run — re-run without --dry-run to stage, then triage with /review-skills)"
exit 0
