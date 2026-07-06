#!/usr/bin/env bash
# Hook guards after the 2026-07-02 CHILD-guard fix: on-stop.sh must RUN in a normal top-level session
# (CLAUDE_CODE_CHILD_SESSION=1, no LOOP_REVIEWER — how this environment presents sessions) and bail only
# for loop-internal claude -p (LOOP_REVIEWER=1). Doubles as the presence self-heal fault-injection —
# the proof the presence path fires at all, since it has zero organic history (0 spawns ever pre-fix).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state" "$tmp/loop/log" "$tmp/loop/bin"
printf 'LOOP_ENABLED=1\n' > "$tmp/loop/config.local.sh"
printf '#!/usr/bin/env bash\n:\n' > "$tmp/loop/bin/selfheal.sh"   # stub worker: records nothing, runs no real garden
hook="$root/loop/hooks/on-stop.sh"; log="$tmp/loop/log/loop.log"
echo x > "$tmp/loop/state/garden.fail"   # self-heal is due (failed garden, no prior catch-up)
rc=0; ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
stdin='{"session_id":"s1","transcript_path":"/nonexistent","cwd":"/tmp"}'   # no transcript → review path exits; only the self-heal path runs
fire() { rm -rf "$tmp/loop/state/selfheal.lock"; : > "$log"; printf '%s' "$stdin" | env CLAUDE_CODE_CHILD_SESSION="$1" LOOP_REVIEWER="$2" bash "$hook" >/dev/null 2>&1; grep -c 'self-heal' "$log" 2>/dev/null; }

ok "$(fire 1 '')" 1 "CHILD=1 top-level → hook RUNS, presence self-heal spawns (the fix + fault-injection proof)"
ok "$(fire 1 x)"  0 "LOOP_REVIEWER=1 → hook bails, no spawn (recursion guard intact)"

exit "$rc"
