#!/usr/bin/env bash
# Recall-probe harness: run fixed probe prompts through the lexical retriever (shadow_score.py) against
# the LIVE MEMORY.md index and report how often the expected memory surfaces (hits@1 / hits@3). A
# repeatable number for "is retrieval degrading as the corpus grows" — run monthly, diff the ratio.
# Measures RETRIEVER recall (what the shadow retriever would inject), which is what its go/no-go needs;
# the heavier "does Claude natively recall" probe (headless claude -p per prompt) is a separate mid-July
# pass. Probes: $1 or $LOOP_DIR/probes.tsv, tab-separated `prompt<TAB>expected_slug` (# comments ok).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1
export LOOP_REVIEWER=1   # loop-session opt-out (this harness is loop-adjacent; see the CHILD-guard memory)
probes="${1:-$LOOP_DIR/probes.tsv}"
[ -f "$probes" ] || { echo "no probe set at $probes (tab-separated: prompt<TAB>expected_slug)"; exit 1; }
n=0 h1=0 h3=0
while IFS=$'\t' read -r prompt expect _; do
  case "$prompt" in ''|'#'*) continue;; esac
  [ -n "${expect:-}" ] || continue
  n=$((n + 1))
  slugs="$(MEM_INDEX="$MEMORY_DIR/MEMORY.md" MV="$MEASUREMENT_VERSION" \
           /usr/bin/python3 "$LOOP_DIR/bin/shadow_score.py" <<<"$prompt" 2>/dev/null | jq -r '.top[].slug' 2>/dev/null)"
  t1="$(printf '%s\n' "$slugs" | head -1)"
  if [ "$t1" = "$expect" ]; then h1=$((h1 + 1)); h3=$((h3 + 1)); v="hit@1"
  elif printf '%s\n' "$slugs" | grep -qxF "$expect"; then h3=$((h3 + 1)); v="hit@3"
  else v="MISS "; fi
  printf '  %s  expect=%-46s top1=%s\n' "$v" "$expect" "${t1:-<none>}"
done < "$probes"
echo "── recall: hits@1 $h1/$n · hits@3 $h3/$n · scorer=$(grep -oE 'SCORER = "[^"]*"' "$LOOP_DIR/bin/shadow_score.py" | cut -d'"' -f2) ──"
