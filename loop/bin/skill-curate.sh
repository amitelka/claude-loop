#!/usr/bin/env bash
# Skill curator (1d) — REPORT-ONLY. Surfaces skill-library health from usage telemetry + inventory +
# git history + pending proposals. Mutates NOTHING — suggestions only; act via /review-skills or by hand.
# Maturity + staleness are computed from a BUILT-IN-FILTERED usage stream (a stale /clear can't fake
# maturity), and "never-used" is SKILL-AGE-AWARE (a freshly-installed skill isn't "stale"). Semantic
# overlap + archive/merge staging are a later LLM-assisted pass. Run: loopctl skill-curate
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
STALE=${SKILL_STALE_DAYS:-30}; ARCH=${SKILL_ARCHIVE_DAYS:-90}
uses="$STATE_DIR/skill-uses.jsonl"; now=$(date +%s)
BUILTINS='["clear","config","compact","context","help","usage","cost","model","resume","exit","quit","status","login","logout","doctor","mcp","memory","agents","hooks","permissions","vim","terminal-setup","bug","release-notes","add-dir","ide","insights","goal"]'
iso2epoch(){ date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null || echo "$now"; }
skill_age_days(){  # days since the skill was first git-added (fallback: SKILL.md mtime)
  local ep; ep=$(skill_git log --diff-filter=A --format=%at -- "$1/SKILL.md" 2>/dev/null | tail -1)
  [ -z "$ep" ] && ep=$(stat -f %m "$SKILLS_DIR/$1/SKILL.md" 2>/dev/null || echo "$now")
  echo $(( (now - ep) / 86400 ))
}

# Filtered usage stream (drop built-in slash commands) — maturity/counts derive from REAL skill use only.
fu=$(mktemp); trap 'rm -f "$fu"' EXIT
[ -s "$uses" ] && jq -c --argjson b "$BUILTINS" 'select((.skill|type=="string") and (((.skill) as $s|$b|index($s))|not))' "$uses" 2>/dev/null > "$fu"
ev=$(wc -l < "$fu" | tr -d ' '); first=""; span=0
[ "$ev" -gt 0 ] && first=$(jq -r '.ts' "$fu" 2>/dev/null | sort | head -1)
[ -n "$first" ] && span=$(( (now - $(iso2epoch "$first")) / 86400 ))
mature=0; { [ "$ev" -gt 0 ] && [ "$span" -ge "$STALE" ]; } && mature=1

echo "── skill curator · REPORT-ONLY (nothing changed) ──"
echo "thresholds: stale >${STALE}d · archive >${ARCH}d · real-skill usage: $ev events over ${span}d $([ "$mature" = 1 ] && echo '(mature → staleness judged)' || echo "(too young → staleness deferred until ≥${STALE}d)")"
echo
echo "Skills (uses · status · flags):"
archlist=""
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue; name=$(basename "${d%/}")
  link=""; [ -L "${d%/}" ] && link="  ⊘symlink(external repo)"
  evf=""; { [ -f "$d/SKILL.md" ] && ! grep -q '^## Triggers' "$d/SKILL.md" 2>/dev/null; } && evf="  ·no-eval-meta"
  cnt=0; last=""
  if [ "$ev" -gt 0 ]; then
    cnt=$(jq -r --arg s "$name" 'select(.skill==$s)|1' "$fu" 2>/dev/null | wc -l | tr -d ' ')
    last=$(jq -r --arg s "$name" 'select(.skill==$s)|.ts' "$fu" 2>/dev/null | sort | tail -1)
  fi
  if [ "${cnt:-0}" -eq 0 ]; then
    sa=$(skill_age_days "$name")
    if [ "$mature" = 1 ] && [ "$sa" -ge "$STALE" ]; then status="never-used (${sa}d old)"; archlist="$archlist  - $name (0 uses, ${sa}d old)\n"
    elif [ "$sa" -lt "$STALE" ]; then status="new (${sa}d, no uses)"
    else status="no uses yet"; fi
  else
    age=$(( (now - $(iso2epoch "$last")) / 86400 ))
    if   [ "$mature" = 1 ] && [ "$age" -gt "$ARCH" ];  then status="ARCHIVE? (${age}d idle)"; archlist="$archlist  - $name (${age}d idle)\n"
    elif [ "$mature" = 1 ] && [ "$age" -gt "$STALE" ]; then status="stale (${age}d)"
    else status="active (${age}d)"; fi
  fi
  printf "  %-28s %3sx  %-20s%s%s\n" "$name" "$cnt" "$status" "$link" "$evf"
done
echo
echo "Archive candidates (suggestion only — NOT archived):"
if [ "$mature" != 1 ]; then echo "  (deferred — real-skill telemetry spans only ${span}d; need ≥${STALE}d to judge staleness)"
elif [ -n "$archlist" ]; then printf '%b' "$archlist"
else echo "  (none)"; fi
echo
echo "Most-used (pin candidates — would be protected once the curator can auto-archive):"
if [ "$ev" -gt 0 ]; then
  jq -s -r 'group_by(.skill)|map({s:.[0].skill,n:length})|sort_by(-.n)|.[:5][]|"  \(.n)x  \(.s)"' "$fu" 2>/dev/null
else echo "  (no real-skill usage logged yet — telemetry is young)"; fi
echo
echo "Pending proposals (await /review-skills):"
np=0
for d in "$PENDING_SKILLS"/*/; do [ -d "$d" ] || continue; np=$((np+1))
  if [ -f "$d/PATCH.md" ]; then echo "  patch → $(basename "${d%/}")"; else echo "  new   → $(basename "${d%/}")"; fi
done
[ "$np" = 0 ] && echo "  (none)"
echo
echo "Recently changed (skills git, 14d):"
skill_git log --since='14 days ago' --pretty='  %ad  %s' --date=short 2>/dev/null | head -8
[ -z "$(skill_git log --since='14 days ago' --oneline 2>/dev/null)" ] && echo "  (none)"
echo
echo "(report-only — act on pending via /review-skills; pin/merge/archive are manual for now."
echo " Semantic overlap-detection + archive/merge staging come in a later LLM-assisted pass.)"
