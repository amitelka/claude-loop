#!/usr/bin/env bash
# tests/run.sh — run every *_test.sh here, tally pass/fail. No deps beyond bash + coreutils + jq.
# Used by CI and locally. Each *_test.sh exits 0 on pass, non-zero on fail, and prints its checks.
# Tracked files are OPERATOR-NEUTRAL: no personal names, personal preferences, or private-corpus context — the word is "operator".
# Two-tier test layout (deliberate): repo-root tests/ = public, self-contained, CI-run (this runner). loop/tests/
# = LOCAL-ONLY tests that touch private-corpus fixtures (memory-global, the private probe set); they skip loudly
# on machines without them and are NOT globbed here on purpose — do not "fix" this by pointing CI at loop/tests/.
set -uo pipefail
cd "$(dirname "$0")"
pass=0 fail=0 failed=""
for t in *_test.sh; do
  [ -f "$t" ] || continue
  echo "── $t ──"
  if bash "$t"; then pass=$((pass + 1)); else fail=$((fail + 1)); failed="$failed $t"; fi
done
echo "════ $pass passed, $fail failed ════${failed:+  (failed:$failed)}"
[ "$fail" = 0 ]
