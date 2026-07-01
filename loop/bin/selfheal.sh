#!/usr/bin/env bash
# selfheal.sh — detached self-heal worker for the Stop/SessionStart hooks. Runs the garden and miner
# catch-ups SYNCHRONOUSLY in priority order (garden first) so they never race for store.lock. Each
# call is a no-op unless its own trigger is due; cooldowns are stamped inside the maybe_* helpers.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 0
trap 'rm -rf "$STATE_DIR/selfheal.lock" 2>/dev/null' EXIT   # release the single-worker gate maybe_selfheal_async took
maybe_garden_catchup
maybe_miner_catchup
