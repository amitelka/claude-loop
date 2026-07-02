#!/usr/bin/env bash
# SessionStart hook: surface (1) what the loop changed in memory-global since the user's
# last session, and (2) anything pending review. exit-0 stdout is added to context for Claude to relay.
# Silent when there's nothing to report.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0

cat > /dev/null 2>&1                                     # drain stdin
[ -n "${LOOP_REVIEWER:-}" ] && exit 0   # loop-internal claude -p opt-out (NOT CLAUDE_CODE_CHILD_SESSION — set on normal sessions here; see on-stop.sh)

maybe_selfheal_async   # fresh-launch self-heal (garden+miner); the Stop hook covers already-open sessions

nl=$'\n'; body=""
clean() { grep -v 'MEMORY.md' | sed 's#.*/##; s/\.md$//' | paste -sd, - | sed 's/,/, /g'; }

# 1) What the loop wrote/changed in memory-global since the last session (git-tracked).
seen="$STATE_DIR/last-seen-ref"
if mem_git rev-parse --git-dir >/dev/null 2>&1; then
  cur="$(mem_git rev-parse HEAD 2>/dev/null || true)"
  ref="$(cat "$seen" 2>/dev/null || true)"
  if [ -n "$ref" ] && [ -n "$cur" ] && [ "$ref" != "$cur" ] && mem_git cat-file -e "$ref" 2>/dev/null; then
    added="$(mem_git diff --name-status "$ref" "$cur" -- '*.md' 2>/dev/null | awk '$1=="A"{print $2}' | clean)"
    mod="$(mem_git   diff --name-status "$ref" "$cur" -- '*.md' 2>/dev/null | awk '$1=="M"{print $2}' | clean)"
    gard="$(mem_git log --format=%s "$ref..$cur" 2>/dev/null | grep -c 'post-garden')"
    [ -n "$added" ]        && body="$body$nl   + new memories: $added"
    [ -n "$mod" ]          && body="$body$nl   ~ updated: $mod"
    [ "${gard:-0}" -gt 0 ] && body="$body$nl   • ${gard} gardener pass(es)"
  fi
  [ -n "$cur" ] && printf '%s' "$cur" > "$seen"          # advance the marker
fi

# 2) Pending review queue.
ps="$(pending_skill_count)"
pm="$(find "$PENDING_MEM" -maxdepth 1 -name '*.md' ! -name '*.WHY.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "${ps:-0}" -gt 0 ] && body="$body$nl   $ps skill proposal(s) pending → /review-skills"
[ "${pm:-0}" -gt 0 ] && body="$body$nl   $pm memory proposal(s) pending → /review-memories"

[ -n "$body" ] || exit 0
printf '🌱 Self-improving loop — since the user was last here:%s%s%s(Surface this to the user at a natural break; do not interrupt their first request.)\n' "$body" "$nl" "$nl"
exit 0
