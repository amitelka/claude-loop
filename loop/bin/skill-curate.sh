#!/usr/bin/env bash
# Skill curator (1d) — REPORT-ONLY. Surfaces skill-library health from usage telemetry + inventory +
# git history + pending proposals. Mutates NOTHING — suggestions only; act via /review-skills or by hand.
# Staleness/archive judgments are SUPPRESSED until the usage telemetry is at least STALE days old
# (otherwise "no data yet" masquerades as "unused"). Semantic overlap + archive/merge staging are a
# later LLM-assisted pass. Run: loopctl skill-curate
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
STALE=${SKILL_STALE_DAYS:-30}; ARCH=${SKILL_ARCHIVE_DAYS:-90}
uses="$STATE_DIR/skill-uses.jsonl"; now=$(date +%s)
BUILTINS='["clear","config","compact","context","help","usage","cost","model","resume","exit","quit","status","login","logout","doctor","mcp","memory","agents","hooks","permissions","vim","terminal-setup","bug","release-notes","add-dir","ide","insights","goal"]'
iso2epoch(){ date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null || echo "$now"; }

ev=$([ -s "$uses" ] && wc -l < "$uses" | tr -d ' ' || echo 0)
first=""; [ -s "$uses" ] && first=$(jq -r '.ts' "$uses" 2>/dev/null | sort | head -1)
span=0; [ -n "$first" ] && span=$(( (now - $(iso2epoch "$first")) / 86400 ))
mature=0; { [ "$ev" -gt 0 ] && [ "$span" -ge "$STALE" ]; } && mature=1

echo "── skill curator · REPORT-ONLY (nothing changed) ──"
echo "thresholds: stale >${STALE}d · archive >${ARCH}d/never-used · usage: $ev events over ${span}d $([ "$mature" = 1 ] && echo '(mature → staleness judged)' || echo "(too young → staleness deferred until ≥${STALE}d)")"
echo
echo "Skills (uses · status · flags):"
archlist=""
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue; name=$(basename "${d%/}")
  link=""; [ -L "${d%/}" ] && link="  ⊘symlink(external repo)"
  evf=""; { [ -f "$d/SKILL.md" ] && ! grep -q '^## Triggers' "$d/SKILL.md" 2>/dev/null; } && evf="  ·no-eval-meta"
  cnt=0; last=""
  if [ -s "$uses" ]; then
    cnt=$(jq -r --arg s "$name" 'select(.skill==$s)|1' "$uses" 2>/dev/null | wc -l | tr -d ' ')
    last=$(jq -r --arg s "$name" 'select(.skill==$s)|.ts' "$uses" 2>/dev/null | sort | tail -1)
  fi
  if [ "${cnt:-0}" -eq 0 ]; then
    if [ "$mature" = 1 ]; then status="never-used"; archlist="$archlist  - $name (never used in ${span}d)\n"; else status="no uses yet"; fi
  else
    age=$(( (now - $(iso2epoch "$last")) / 86400 ))
    if   [ "$mature" = 1 ] && [ "$age" -gt "$ARCH" ];  then status="ARCHIVE? (${age}d)"; archlist="$archlist  - $name (${age}d idle)\n"
    elif [ "$mature" = 1 ] && [ "$age" -gt "$STALE" ]; then status="stale (${age}d)"
    else status="active (${age}d)"; fi
  fi
  printf "  %-28s %3sx  %-16s%s%s\n" "$name" "$cnt" "$status" "$link" "$evf"
done
echo
echo "Archive candidates (suggestion only — NOT archived):"
if [ "$mature" != 1 ]; then echo "  (deferred — telemetry spans only ${span}d; need ≥${STALE}d of history to judge staleness)"
elif [ -n "$archlist" ]; then printf '%b' "$archlist"
else echo "  (none)"; fi
echo
echo "Most-used (pin candidates — would be protected once the curator can auto-archive):"
if [ -s "$uses" ] && [ "$(jq -s 'length' "$uses" 2>/dev/null || echo 0)" -gt 0 ]; then
  jq -s -r --argjson b "$BUILTINS" 'map(select(.skill as $s | ($b|index($s))|not))|group_by(.skill)|map({s:.[0].skill,n:length})|sort_by(-.n)|.[:5][]|"  \(.n)x  \(.s)"' "$uses" 2>/dev/null
else echo "  (no usage logged yet — telemetry is young)"; fi
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
