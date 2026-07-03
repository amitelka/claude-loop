#!/usr/bin/env bash
# Log-tag contract: every tag in loop/tags.sh (the single source stats/doctor grep via) MUST be
# emitted by some writer's log "..." line, and loopctl must reference the vars (not literals).
# Guards the failure that made `last review` read 9 days stale — a review.sh refactor dropped
# `review: done` while loopctl still greped it. Now drift fails CI instead of silently reading 0.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
writers=("$root/loop/bin" "$root/loop/hooks" "$root/loop/lib.sh")
# shellcheck source=/dev/null
. "$root/loop/tags.sh"
rc=0

emitted() { grep -rqE "log \"[^\"]*$1" "${writers[@]}" 2>/dev/null; }
check() {  # $1 = var name, $2 = value
  if [ -z "$2" ]; then echo "  FAIL  $1 is empty in tags.sh"; rc=1
  elif emitted "$2"; then echo "  ok    $1='$2' — emitted by a writer"
  else echo "  FAIL  $1='$2' — NO writer emits it (drift)"; rc=1; fi
}

for v in TAG_REVIEW_START TAG_REVIEW_OK TAG_HARVEST TAG_GARDEN_START TAG_STOP_TRIGGER \
         TAG_SESSION_END TAG_SELFHEAL TAG_GARDEN_CATCHUP TAG_MINER_CATCHUP TAG_MINE_DONE TAG_MINE_FAILED \
         TAG_REGRET TAG_INDEX_REBUILD TAG_LOOP_DISABLED; do
  check "$v" "${!v-}"
done

# Consumers must reference the vars, not silently revert to string literals:
if grep -q 'TAG_REVIEW_START' "$root/loop/bin/loopctl"; then echo "  ok    loopctl references the TAG_* registry"
else echo "  FAIL  loopctl no longer references TAG_* vars (reverted to literals?)"; rc=1; fi

exit "$rc"
