#!/usr/bin/env bash
# Probes-CI regression guard. Runs the SHIPPED scorer (loop/bin/shadow_score.py) through the SHIPPED index
# build (build_index.py) over memory-global pinned at the A/B rev, and fails if recall@3 regresses below the
# shipped baseline. Re-run on every scorer / index-policy change (the escalation-path discipline).
#
# LOCAL-ONLY by design: the probe fixture (probes.jsonl) contains prompts and slugs from the operator's private
# corpus (gitignored), and the pinned rev exists only in the operator's local memory-global. So on any other
# machine (incl. public CI) this SKIPS LOUDLY — a green run must
# never be misread as "probes passed" when they never executed (the silent-truncation lesson, in test costume).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
scorer="$root/loop/bin/shadow_score.py"
probes="$here/probes.jsonl"
memrepo="${MEMORY_GLOBAL:-$HOME/.claude/memory-global}"
rev="d7783f1"          # A/B pinned rev; bump only alongside a re-baselined recall number
baseline=24            # shipped bm25f-1 recall@3 over the 28 positives (see migration-ab-packet.md)

skip(){ echo "SKIPPED: $1 (local-only probes-CI; NOT run)"; exit 0; }
[ -f "$probes" ]                                    || skip "probes fixture absent"
git -C "$memrepo" rev-parse --git-dir >/dev/null 2>&1 || skip "memory-global not a git repo at $memrepo"
git -C "$memrepo" cat-file -t "$rev" >/dev/null 2>&1  || skip "pinned rev $rev absent in memory-global"
command -v jq >/dev/null 2>&1                        || skip "jq absent"

art="$(mktemp)"; trap 'rm -f "$art"' EXIT
/usr/bin/python3 "$here/run_probes.py" --rev "$rev" --probes "$probes" --scorer "$scorer" \
  --memrepo "$memrepo" --out "$art" || { echo "  FAIL  harness errored"; exit 1; }
r3="$(jq -r '.recall_at_3' "$art")"; n="$(jq -r '.n_pos' "$art")"
if [ "${r3:-0}" -ge "$baseline" ]; then echo "  ok    recall@3=$r3/$n ≥ baseline $baseline (rev $rev)"
else echo "  FAIL  recall@3=$r3/$n < baseline $baseline — scorer regression (rev $rev)"; exit 1; fi

# Operating-point drift WARN (non-failing): BM25 scores are non-stationary (IDF/N/avgdl shift as the corpus grows),
# so the gates.tsv rows-1/2 threshold is a snapshot calibration. Recompute the max-recall operating point from the
# sweep and warn if it has drifted >1.0 from the configured threshold — the alarm to re-baseline (see gates.tsv).
maxrec="$(jq -r '[.precision.sweep[].recall]|max' "$art" 2>/dev/null)"
op="$(jq -r --argjson m "${maxrec:-0}" '[.precision.sweep[]|select(.recall==$m)|.T]|max // 0' "$art" 2>/dev/null)"
tsvT="$(grep -E '^prompt-submit'$'\t' "$(cd "$here/../.." && pwd)/loop/gates.tsv" | awk -F'\t' '{print $5}')"
div="$(awk -v a="${op:-0}" -v b="${tsvT:-0}" 'BEGIN{d=a-b; print (d<0?-d:d)}')"
if awk -v d="$div" 'BEGIN{exit !(d>1.0)}'; then
  echo "  ⚠ operating-point drift: sweep max-recall T=$op vs gates.tsv threshold $tsvT (Δ=$div > 1.0) — re-baseline rows 1-2 (gates.tsv quantile-rule note)"
else echo "  ok    operating point T=$op within 1.0 of gates.tsv threshold $tsvT"; fi
