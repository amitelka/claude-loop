#!/usr/bin/env bash
# Self-heal decision gates (garden_catchup_due / miner_catchup_due) — the state machine that
# recovers a missed/failed gardener or miner. Sources the real lib.sh against a temp CLAUDE_CONFIG_DIR
# so nothing touches the live install. Formalizes the ad-hoc checks run when the machinery was built.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp"; mkdir -p "$tmp/loop/state"
# shellcheck source=/dev/null
. "$root/loop/lib.sh" 2>/dev/null || { echo "  FAIL  cannot source lib.sh"; exit 1; }
mkdir -p "$STATE_DIR"
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

exit "$rc"
