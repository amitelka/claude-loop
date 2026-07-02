#!/usr/bin/env bash
# Log-tag contract: every string that loopctl's stats/doctor greps for MUST be emitted by some
# writer's log "..." line. Guards the exact failure that made `last review` read 9 days stale —
# a review.sh refactor dropped `review: done` while loopctl still greped it. If a writer renames
# a tag without updating the consumer (or vice-versa), this test fails instead of silently reading 0.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
writers=("$root/loop/bin" "$root/loop/hooks" "$root/loop/lib.sh")
rc=0

emitted() { grep -rqE "log \"[^\"]*$1" "${writers[@]}" 2>/dev/null; }
check() {  # $1 = substring a consumer greps for ; $2 = which consumer depends on it
  if emitted "$1"; then echo "  ok    emitted: '$1'"
  else echo "  FAIL  no writer emits '$1'  (consumer: $2)"; rc=1; fi
}

# loopctl stats/doctor consumer strings → the writer that must keep emitting them:
check 'review: start'       'stats reviews-started + last-review'
check 'valid proposal'      'stats reviews-ok'
check 'harvest: nightly'    'stats triggers-harvest'
check 'garden: start'       'stats triggers-garden'
check 'stop: trigger'       'stats triggers-stop'
check 'session-end: review' 'stats triggers-session-end'
check 'self-heal'           'stats self-heal presence-spawns'
check 'garden catch-up'     'stats self-heal garden-catchup'
check 'miner catch-up'      'stats self-heal miner-catchup'
check 'mine-skills: done'   'stats miner runs (real/dry)'
check 'mine-skills: FAILED' 'stats miner fails'

exit "$rc"
