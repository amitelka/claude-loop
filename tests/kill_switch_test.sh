#!/usr/bin/env bash
# Kill-switch contract: LOOP_ENABLED=0 makes every autonomous/detached entry point inert (exit 0, one skip
# tag, ZERO spend, ZERO cooldown/stamp side-effect, HEAD unchanged), while operator-control commands and
# manual invocations still work — and the guard-set can't silently regress. Public-safe: temp
# CLAUDE_CONFIG_DIR + a stub `claude` (the spend instrument — a broken guard would invoke it, so an ABSENT
# marker proves inertness; the enabled + manual arms prove the guard does not over-block). No private corpus.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
rc=0
ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
has(){ case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }
present(){ [ -e "$1" ] && echo yes || echo no; }

CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL  claude-loop install errored"; exit 1; }
export CLAUDE_CONFIG_DIR="$tmp"
L="$tmp/loop"
mkdir -p "$LOOP_HOME/memory-global"
# a VALID store (both index tiers + a body each): garden's #16 pre-spend backstop now refuses to spend on an
# INVALID/empty store, so to isolate the kill-switch guard the store must be valid here (not a bare empty commit).
printf -- '---\nname: ks-hot\nmetadata:\n  type: feedback\n---\nx\n' > "$LOOP_HOME/memory-global/ks-hot.md"
printf -- '---\nname: ks-cold\nmetadata:\n  type: reference\n---\nx\n' > "$LOOP_HOME/memory-global/ks-cold.md"
printf -- '- [ks-hot](ks-hot.md) — hot\n'  > "$LOOP_HOME/memory-global/MEMORY.md"
printf -- '- [ks-cold](ks-cold.md) — cold\n' > "$LOOP_HOME/memory-global/ARCHIVE.md"
git -C "$LOOP_HOME/memory-global" init -q 2>/dev/null
git -C "$LOOP_HOME/memory-global" -c user.email=t@t -c user.name=t add -A 2>/dev/null
git -C "$LOOP_HOME/memory-global" -c user.email=t@t -c user.name=t commit -q -m base 2>/dev/null

# stub `claude` = the SPEND instrument (all entry points call bare `claude`, PATH-resolved, inherited by children)
sbin="$tmp/stubbin"; mkdir -p "$sbin"; spend="$tmp/claude-was-called"
printf '#!/usr/bin/env bash\ntouch %q\nprintf %%s "{\\"is_error\\":false,\\"result\\":\\"stub\\"}"\n' "$spend" > "$sbin/claude"
chmod +x "$sbin/claude"; export PATH="$sbin:$PATH"

set_enabled(){ printf 'LOOP_ENABLED=%s\n' "$1" > "$L/config.local.sh"; }

# ── TIGHTENING 2 — PREFLIGHT: resolved store paths MUST be under the temp root, else ABORT (never touch the real store) ──
eval "$(bash -c ". \"$L/lib.sh\"; printf 'P_MEM=%q\nP_STATE=%q\nP_LOG=%q\n' \"\$MEMORY_DIR\" \"\$STATE_DIR\" \"\$LOG\"")"
for pv in P_MEM P_STATE P_LOG; do
  case "${!pv}" in "$tmp"/*) ;; *) echo "  FATAL preflight: $pv=${!pv} escapes the temp root — ABORT"; exit 1;; esac
done
echo "  ok    preflight: MEMORY_DIR/STATE_DIR/LOG all under the temp root"
mkdir -p "$(dirname "$P_LOG")" "$P_STATE"
state_sig(){ find "$P_STATE" -type f 2>/dev/null | LC_ALL=C sort | shasum | awk '{print $1}'; }
memhead(){ git -C "$LOOP_HOME/memory-global" rev-parse HEAD 2>/dev/null; }
skipc(){ grep -c "$1: skip: LOOP_ENABLED=0" "$P_LOG" 2>/dev/null | tr -d ' '; }

# ── PART 1 — BEHAVIORAL: LOOP_ENABLED=0 → each autonomous entry point is inert ──
echo "── Part 1: disabled autonomous entry points are inert ──"
set_enabled 0
for spec in "garden.sh||garden" "harvest.sh||harvest" "garden-then-mine.sh||garden-then-mine" "mine-skills.sh|--scheduled|mine-skills"; do
  IFS='|' read -r sfile sargs sname <<< "$spec"
  rm -f "$spend"; s0="$(state_sig)"; h0="$(memhead)"
  # shellcheck disable=SC2086
  bash "$L/bin/$sfile" $sargs >/dev/null 2>&1; ec=$?
  ok "$ec" 0 "$sname: exit 0 (disabled)"
  ok "$(skipc "$sname")" 1 "$sname: emits the skip tag exactly once"
  ok "$(present "$spend")" no "$sname: NO spend (claude not called)"
  ok "$(state_sig)" "$s0" "$sname: NO STATE_DIR side-effect (no cooldown/lock/stamp)"
  ok "$(memhead)" "$h0" "$sname: memory-global HEAD unchanged"
done

# ── INVERSE A (tightening 1) — enabled → guard PASSES; entry point reaches the spend point (marker PRESENT) ──
echo "── Inverse A: enabled → guard lets the entry point through to spend ──"
ac0="$(skipc garden)"
set_enabled 1; rm -f "$spend"
bash "$L/bin/garden.sh" >/dev/null 2>&1 || true
ok "$(present "$spend")" yes "inverse A: enabled garden reached the spend point (guard passed — claude called)"
ok "$(skipc garden)" "$ac0" "inverse A: enabled garden emitted NO new skip tag"

# ── INVERSE B (tightening 4) — disabled, MANUAL mine-skills (no args) is NOT gated by the kill switch ──
echo "── Inverse B: manual mine-skills is not kill-switched (operator command) ──"
set_enabled 0; bc0="$(skipc mine-skills)"; rm -f "$spend"
bash "$L/bin/mine-skills.sh" >/dev/null 2>&1 || true
ok "$(skipc mine-skills)" "$bc0" "inverse B: manual mine-skills emitted NO skip tag (not kill-switched)"
ok "$(present "$spend")" yes "inverse B: manual mine-skills reached the spend point (past the guard)"

# ── PART 2 — CONTRACT (static regression guard) ──
echo "── Part 2: guard-set contract ──"
# shellcheck disable=SC1090
. "$L/lib.sh" >/dev/null 2>&1
for e in "${LOOP_AUTONOMOUS_ENTRYPOINTS[@]}"; do
  ok "$(grep -qE 'guard_loop_enabled|loop_enabled' "$L/bin/$e" && echo yes || echo no)" yes "contract (a): $e references the guard"
done
reg="$(awk '/install-schedule\)/,/;;/' "$L/bin/loopctl" | grep -oE 'bin/[a-z-]+\.sh' | sed 's#bin/##' | LC_ALL=C sort -u)"
[ -n "$reg" ] && for r in $reg; do
  case " ${LOOP_AUTONOMOUS_ENTRYPOINTS[*]} " in *" $r "*) echo "  ok    contract (b): registered $r ∈ autonomous array";; *) echo "  FAIL  contract (b): registered $r NOT in the array"; rc=1;; esac
done
ok "$(grep -c 'guard_loop_enabled' "$L/bin/loopctl" 2>/dev/null | tr -d ' ')" 0 "contract (c): loopctl does NOT call guard_loop_enabled (control cmds stay usable)"

# ── PART 3 — schedule_doctor_verdict 2×2 (pure helper, hermetic; no real launchctl) ──
echo "── Part 3: doctor schedule verdict 2×2 ──"
o="$(schedule_doctor_verdict 1 3)"; ec=$?; ok "$ec" 0 "2×2 enabled+loaded → ok"; ok "$(has "$o" "agents loaded")" yes "  msg: agents loaded"
o="$(schedule_doctor_verdict 1 1)"; ec=$?; ok "$ec" 1 "2×2 enabled+absent → warn"; ok "$(has "$o" "idle maintenance off")" yes "  msg: idle maintenance off"
o="$(schedule_doctor_verdict 0 0)"; ec=$?; ok "$ec" 0 "2×2 disabled+absent → coherent (ok)"; ok "$(has "$o" "coherent")" yes "  msg: coherent"
o="$(schedule_doctor_verdict 0 2)"; ec=$?; ok "$ec" 1 "2×2 disabled+loaded → warn"; ok "$(has "$o" "no-op")" yes "  msg: scheduled runs no-op"

# ── Part 4 — disabled HOOKS are fully inert: zero stdout + zero STATE_DIR writes (xhigh P1, full-inert ruling) ──
echo "── Part 4: disabled hooks fully inert ──"
set_enabled 0
hin='{"session_id":"s1","prompt_id":"p1","tool_name":"Read","tool_input":{"file_path":"'"$P_MEM"'/x.md","skill":"foo"},"hook_event_name":"PostToolUse","cwd":"'"$tmp"'"}'
for h in on-precompact on-read on-session-start on-skill-use on-stop on-session-end; do
  s0="$(state_sig)"; out="$(printf '%s' "$hin" | bash "$L/hooks/$h.sh" 2>/dev/null)"
  ok "${out:-EMPTY}" EMPTY "$h: zero stdout when disabled"
  ok "$(state_sig)" "$s0" "$h: zero STATE_DIR writes when disabled"
done
s0="$(state_sig)"; out="$(printf '%s' "$hin" | bash "$L/bin/gate-runner.sh" prompt-submit 2>/dev/null)"
ok "${out:-EMPTY}" EMPTY "gate-runner: zero stdout when disabled"
ok "$(state_sig)" "$s0" "gate-runner: zero STATE_DIR writes when disabled"

exit "$rc"
