#!/usr/bin/env bash
# #23 worker permission profiles: repo TEMPLATES (@@LH@@ placeholder) materialized with realpath(LOOP_HOME) into
# $PROFILES_DIR at install/reprofile. Workers spawn `claude -p --settings <profile>` in DEFAULT mode so the platform
# enforces least privilege. Assert: all three materialized, no placeholder left, //-realpath rule form, correct
# per-worker scope (reviewer/miner → proposals only; gardener → memory-global + log, .git denied), and the doctor
# freshness verdict (fresh after install; STALE when a profile is missing; reprofile restores).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL install"; exit 1; }
L="$tmp/loop"; . "$L/lib.sh" >/dev/null 2>&1
rc=0; ok(){ if [ "$1" = "$2" ]; then :; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
has(){ grep -qF -- "$2" "$1" && echo yes || echo no; }

PD="$PROFILES_DIR"; abs="$(loop_abs)"; want="//${abs#/}"
for w in reviewer gardener miner; do
  ok "$([ -f "$PD/$w.permissions.json" ]&&echo y||echo n)" y "$w profile materialized"
  ok "$(grep -c '@@LH@@' "$PD/$w.permissions.json" 2>/dev/null|tr -d ' ')" 0 "$w profile has NO unsubstituted @@LH@@"
done
# //-realpath rule form (symlink-resolved absolute)
ok "$(has "$PD/reviewer.permissions.json" "$want/proposals/")" yes "reviewer profile uses //realpath(LOOP_HOME)"
# per-worker SCOPE
ok "$(has "$PD/reviewer.permissions.json" "Write($want/proposals/**)")" yes "reviewer: Write scoped to proposals/**"
ok "$(has "$PD/reviewer.permissions.json" "memory-global")" no "reviewer: NO memory-global grant (proposals only)"
ok "$(has "$PD/miner.permissions.json" "$want/proposals/")" yes "miner: Write scoped to proposals/**"
ok "$(has "$PD/gardener.permissions.json" "Write($want/memory-global/**)")" yes "gardener: Write scoped to memory-global/**"
ok "$(jq -e '.permissions.deny[]? | select(contains(".git"))' "$PD/gardener.permissions.json" >/dev/null 2>&1 && echo yes || echo no)" yes "gardener: memory-global/.git DENIED"
# profiles are valid JSON
for w in reviewer gardener miner; do ok "$(jq -e . "$PD/$w.permissions.json" >/dev/null 2>&1 && echo ok||echo bad)" ok "$w profile is valid JSON"; done
# worker_profile echoes the path
ok "$(worker_profile reviewer)" "$PD/reviewer.permissions.json" "worker_profile reviewer → path"

# doctor freshness (capture output to a var — piping into `grep -q` under pipefail SIGPIPEs the writer → false rc)
profiles_fresh; ok "$?" 0 "profiles_fresh rc0 after install"
dout="$(bash "$L/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"profiles fresh"*) ok yes yes;; *) ok no yes "doctor reports profiles fresh";; esac
# staleness: remove one profile → missing → doctor STALE → reprofile restores
rm -f "$PD/gardener.permissions.json"
profiles_fresh >/dev/null 2>&1; ok "$?" 1 "profiles_fresh rc1 when a profile is missing"
dout="$(bash "$L/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"profiles STALE"*) ok yes yes;; *) ok no yes "doctor reports profiles STALE";; esac
bash "$L/bin/loopctl" reprofile >/dev/null 2>&1
ok "$([ -f "$PD/gardener.permissions.json" ]&&echo y||echo n)" y "reprofile re-materialized the missing profile"
profiles_fresh >/dev/null 2>&1; ok "$?" 0 "profiles_fresh rc0 after reprofile"

# P0-1 (integrity ≠ freshness): an ADDED grant keeps the realpath prefix but is a different control file → must fail
python3 - "$PD/reviewer.permissions.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["permissions"]["allow"].append("Write(//etc/**)"); json.dump(d,open(p,"w"))
PY
profiles_fresh >/dev/null 2>&1; ok "$?" 1 "P0-1: profiles_fresh rc1 on a tampered profile (extra allow grant)"
worker_profile reviewer >/dev/null 2>&1; ok "$?" 1 "P0-1: worker_profile refuses the tampered profile (fail-closed)"
dout="$(bash "$L/bin/loopctl" doctor 2>/dev/null)"
case "$dout" in *"STALE/TAMPERED"*|*"profiles STALE"*) ok yes yes;; *) ok no yes "P0-1: doctor flags the tampered profile";; esac
bash "$L/bin/loopctl" reprofile >/dev/null 2>&1
worker_profile reviewer >/dev/null 2>&1; ok "$?" 0 "P0-1: reprofile restores byte-exact → worker_profile accepts again"

echo "  (profiles: $( [ "$rc" = 0 ] && echo ALL GREEN || echo has failures ))"
exit "$rc"