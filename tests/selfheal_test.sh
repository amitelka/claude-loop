#!/usr/bin/env bash
# Self-heal decision gates (garden_catchup_due / miner_catchup_due) — the state machine that
# recovers a missed/failed gardener or miner. Sources the real lib.sh against a temp CLAUDE_CONFIG_DIR
# so nothing touches the live install. Formalizes the ad-hoc checks run when the machinery was built.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state"
# shellcheck source=/dev/null
. "$root/loop/lib.sh" 2>/dev/null || { echo "  FAIL  cannot source lib.sh"; exit 1; }
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
now="$(date +%s)"; rc=0
ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

# ── garden_catchup_due: (stale>24h OR garden.fail) AND >2h since last attempt ──
echo "$now" > "$STATE_DIR/garden.success"; rm -f "$STATE_DIR/garden.fail" "$STATE_DIR/garden.catchup"
garden_catchup_due >/dev/null; ok "$?" 1 "fresh success, no fail → not due"

echo x > "$STATE_DIR/garden.fail"; echo "$((now - 7201))" > "$STATE_DIR/garden.catchup"
reason="$(garden_catchup_due)"; due=$?
ok "$due" 0 "fail + cooldown elapsed → due"
ok "$reason" "previous-fail" "reason = previous-fail"

echo "$now" > "$STATE_DIR/garden.catchup"     # attempt just now
garden_catchup_due >/dev/null; ok "$?" 1 "fail but cooldown NOT elapsed → not due"

rm -f "$STATE_DIR/garden.fail"; echo "$((now - 86401))" > "$STATE_DIR/garden.success"; rm -f "$STATE_DIR/garden.catchup"
reason="$(garden_catchup_due)"; ok "$?" 0 "stale >24h → due"; ok "$reason" "stale" "reason = stale"

# ── miner_catchup_due: enabled AND skill-miner.fail AND >2h since last attempt ──
rm -f "$STATE_DIR/skill-miner.catchup"; echo x > "$STATE_DIR/skill-miner.fail"
SKILL_MINER_ENABLED=1 miner_catchup_due; ok "$?" 0 "enabled + fail → due"
SKILL_MINER_ENABLED=0 miner_catchup_due; ok "$?" 1 "disabled → not due"
SKILL_MINER_ENABLED=1; rm -f "$STATE_DIR/skill-miner.fail"
miner_catchup_due; ok "$?" 1 "enabled, no fail marker → not due"

# ── maybe_selfheal_async: atomic single-worker gate (concurrent Stop/SessionStart hooks → ≤1 worker) ──
export LOOP_ENABLED=1 SKILL_MINER_ENABLED=0
rm -f "$STATE_DIR/garden.success" "$STATE_DIR/garden.catchup" "$STATE_DIR/selfheal.lock"
echo x > "$STATE_DIR/garden.fail"                                   # garden catch-up is due
mkdir -p "$LOOP_DIR/bin"                                            # stub worker that does NOT release the gate,
printf '#!/usr/bin/env bash\n:\n' > "$LOOP_DIR/bin/selfheal.sh"     # so the held lock is what blocks re-spawns
: > "$LOG"
maybe_selfheal_async; maybe_selfheal_async; maybe_selfheal_async    # 3 concurrent-ish fires
ok "$(grep -c 'self-heal' "$LOG")" 1 "3 fires, gate held → exactly 1 worker spawned"
rm -rf "$STATE_DIR/selfheal.lock"; maybe_selfheal_async             # gate released
ok "$(grep -c 'self-heal' "$LOG")" 2 "gate released → next fire spawns"
LOOP_ENABLED=0; rm -rf "$STATE_DIR/selfheal.lock"; : > "$LOG"; maybe_selfheal_async
ok "$(grep -c 'self-heal' "$LOG")" 0 "LOOP_ENABLED=0 → no spawn"

exit "$rc"
