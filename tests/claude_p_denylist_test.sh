#!/usr/bin/env bash
# Contract (#23 seam): the LLM workers (reviewer/gardener/miner) run UNTRUSTED input — transcript slices, memory
# bodies — so a `--disallowedTools` denylist incl. Bash must gate every spawn (belt-and-suspenders behind the
# platform-scoped profile). Since #23 the spawn is centralized in ONE seam, `worker_spawn` (lib.sh), so the
# contract has three parts: (1) the sole `claude -p` lives in worker_spawn and carries `--disallowedTools`;
# (2) NO worker script spawns `claude -p` directly (bypassing the seam + its profile/denylist); (3) every
# worker_spawn CALL-SITE passes a disallowed-list argument that includes Bash. Guards the CLASS, not three scripts.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; rc=0
lib="$root/loop/lib.sh"
real(){ grep -nE "$1" "$2" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#'; }   # non-comment matches

# (1) the seam itself: worker_spawn's claude -p carries --disallowedTools
if grep -q 'claude -p' "$lib" && grep -A6 'claude -p' "$lib" | grep -q -- '--disallowedTools'; then
  echo "  ok    worker_spawn (lib.sh) claude -p carries --disallowedTools"
else
  echo "  FAIL  worker_spawn does not carry --disallowedTools"; rc=1
fi

# (2) no worker script spawns claude -p directly (the seam is the only spawn path)
direct=0
for f in "$root"/loop/bin/*.sh; do
  real 'claude -p' "$f" >/dev/null || continue
  echo "  FAIL  $(basename "$f") spawns claude -p directly — must go through worker_spawn (seam bypass loses profile+denylist)"; direct=1; rc=1
done
[ "$direct" = 0 ] && echo "  ok    no worker script bypasses the worker_spawn seam"

# (3) every worker_spawn call-site passes a disallowed-list arg containing Bash
n=0
for f in "$root"/loop/bin/*.sh; do
  while IFS= read -r line; do
    n=$((n+1))
    case "$line" in *Bash*) :;; *) echo "  FAIL  $(basename "$f") worker_spawn call omits Bash from its disallowed list: $line"; rc=1;; esac
  done < <(real 'worker_spawn ' "$f")
done
[ "$n" -ge 3 ] || { echo "  FAIL  expected ≥3 worker_spawn call-sites (review/garden/mine), found $n — sweep drift?"; rc=1; }
echo "  ($n worker_spawn call-site(s) checked)"
exit "$rc"