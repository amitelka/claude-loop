#!/usr/bin/env bash
# Contract: the reviewer prompt is SLICE-ONLY — it must NOT instruct the reviewer to browse the memory store
# (read MEMORY.md / Grep the store) before proposing. The A/B experiment (2026-07-05) showed store-browsing
# SUPPRESSED capture (A captured 20/41 worthy items vs slice-only B1's 36/41, Δ=−16 on the ±1 gate); dedup
# correctness moved downstream to materialize exact-reject + the nightly gardener's near-dup merge. This guards
# against the browse/dedup instruction silently returning to review.md. Public-safe (greps shipped source).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; f="$root/loop/prompts/review.md"; rc=0
[ -f "$f" ] || { echo "  FAIL  $f missing"; exit 1; }
# must NOT re-introduce store-browsing
if grep -qiE 'Dedup awareness|read .*MEMORY\.md|Grep .*MEMORY_DIR|check what already exists' "$f"; then
  echo "  FAIL  review.md re-introduced a store-browse/dedup instruction — reviewer must judge the slice only (dedup is the gardener's + materialize's job)"; rc=1
else
  echo "  ok    review.md carries no store-browse/dedup instruction (slice-only reviewer)"
fi
# must STILL read its slice + apply POLICY (exemplars live there)
grep -q '{{SLICE_FILE}}' "$f" && echo "  ok    still reads {{SLICE_FILE}}" || { echo "  FAIL  review.md no longer reads its slice"; rc=1; }
grep -q '{{POLICY}}' "$f" && echo "  ok    still injects {{POLICY}} (capture bar + exemplars)" || { echo "  FAIL  review.md dropped {{POLICY}}"; rc=1; }
exit "$rc"