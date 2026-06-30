#!/usr/bin/env bash
# Skill candidate-miner (1b) — MANUAL-FIRST, not scheduled. Mines memory-global + skill usage for
# reusable procedures and stages NEW skills or PATCHES to existing ones into pending/skills (human-gated
# via /review-skills; NEVER auto-installs). `mine-skills.sh --dry-run` shows candidates without staging.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1
dry=0; force=0; sched=0; catchup=0; for a in "$@"; do case "$a" in --dry-run) dry=1;; --force) force=1;; --scheduled) sched=1;; --catch-up) catchup=1;; esac; done
# --catch-up = self-heal mode (harvest, after a confirmed garden): bypasses the cadence floor (the corpus
# just changed) but still honors enabled / skip-if-unchanged / rejected-dedup / store.lock — NOT blunt --force.
{ [ "$sched" = 1 ] || [ "$catchup" = 1 ]; } && [ "${SKILL_MINER_ENABLED:-0}" != 1 ] && { log "mine-skills: unattended run but SKILL_MINER_ENABLED=0 — skip"; exit 0; }

acquire_store_lock "mine-skills" || { log "mine-skills: memory store busy (garden or miner running) — skip"; echo "mine-skills: store busy — skip (retry later / after garden finishes)"; exit 0; }
trap 'release_store_lock' EXIT

STATE_FILE="$STATE_DIR/skill-miner.state.json"
fp="$(miner_fingerprint)"
if [ "$sched" = 1 ] && [ "$catchup" != 1 ] && [ "$force" != 1 ]; then   # cadence rate-limit — scheduled only; --catch-up/manual/--force bypass it
  lat="$(jq -r '.last_success_at // 0' "$STATE_FILE" 2>/dev/null)"
  if [ "${lat:-0}" -gt 0 ] && [ "$(( $(date +%s) - lat ))" -lt "$(( ${SKILL_MINER_CADENCE_DAYS:-7} * 86400 ))" ]; then
    log "mine-skills: cadence ${SKILL_MINER_CADENCE_DAYS:-7}d not elapsed (last $(date -r "$lat" '+%F %H:%M' 2>/dev/null)) — skip"; exit 0
  fi
fi
if [ "$force" != 1 ] && [ "${SKILL_MINER_ONLY_IF_CHANGED:-1}" = 1 ]; then
  last="$(jq -r '.last_fingerprint // ""' "$STATE_FILE" 2>/dev/null)"
  if [ -n "$last" ] && [ "$fp" = "$last" ]; then
    lat="$(jq -r '.last_success_at // 0' "$STATE_FILE" 2>/dev/null)"
    log "mine-skills: inputs unchanged since last successful mine — skip"
    echo "mine-skills: unchanged since last successful run ($(date -r "${lat:-0}" '+%F %H:%M' 2>/dev/null || echo '?')); use --force to mine anyway"
    exit 0
  fi
fi

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
log "mine-skills: start model=$SKILL_MINER_MODEL dry=$dry"
raw="$(printf '%s' "$prompt" | claude -p \
  --model "$SKILL_MINER_MODEL" --effort "$SKILL_MINER_EFFORT" \
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
staged=0; rej=0; supp=""
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
  if [ "$force" != 1 ] && skill_is_rejected "$name" "$action"; then
    echo "  suppressed $name ($action — previously rejected; loopctl skill-unreject $name $action to allow)"; supp="$supp${supp:+, }$name"; continue
  fi

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
log "mine-skills: done candidates=$n staged=$staged rejected=$rej suppressed=[$supp] dry=$dry cost=${cost:-?}"
[ -n "$supp" ] && echo "mine-skills: suppressed previously-rejected: $supp (see loopctl skill-rejections)"
[ "$dry" = 0 ] && jq -n --arg fp "$fp" --argjson at "$(date +%s)" --arg p "$proposal" \
  '{last_fingerprint:$fp, last_success_at:$at, last_proposal_path:$p}' > "$STATE_FILE"
[ "$dry" = 1 ] && echo "(dry-run — re-run without --dry-run to stage, then triage with /review-skills)"
exit 0
