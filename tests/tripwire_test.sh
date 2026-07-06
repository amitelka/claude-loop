#!/usr/bin/env bash
# #23 tripwire (new-model, replaces the deleted #16 mirror/guard). The impossible zones — pending/, installed
# skills/, and the .git of memory-global + skills — must not change during a worker's model window (a real worker
# is platform-scoped away from them; a change ⇒ an ungoverned side-effect). Contract:
#   • reviewer/miner: any impossible-zone change → ABORT, no advance / nothing staged (evidence-only, NO restore).
#   • a memory-global BODY change is NOT a zone hit (that is ordinary external traffic → reconciled elsewhere).
#   • garden: a .git change is checked GIT-FREE and aborts BEFORE any git op (r5 ordering) — else a planted
#     core.fsmonitor helper would run on the restore's own git op. Detection precedes the git op that would fire it.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL install"; exit 1; }
L="$tmp/loop"; memdir="$L/memory-global"
printf 'LOOP_ENABLED=1\nLOOP_MODE=active\n' > "$L/config.local.sh"
. "$L/lib.sh" >/dev/null 2>&1
rc=0; ok(){ if [ "$1" = "$2" ]; then :; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

seed(){ rm -rf "$memdir"; mkdir -p "$memdir"
  printf -- '- [base](base.md) — b\n' > "$memdir/MEMORY.md"; printf -- '- [old](old.md) — o\n' > "$memdir/ARCHIVE.md"
  printf -- '---\nname: base\n---\nb\n' > "$memdir/base.md"; printf -- '---\nname: old\n---\no\n' > "$memdir/old.md"
  git -C "$memdir" init -q; git -C "$memdir" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
  git -C "$memdir" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1; }
mkslice(){ printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' > "$tmp/slice.jsonl"; }
sbin="$tmp/sbin"; mkdir -p "$sbin"; PENDING_MEM="${PENDING_MEM:-$L/pending/memories}"; PENDING_SKILLS="${PENDING_SKILLS:-$L/pending/skills}"

echo "── reviewer: pending-write in window → tripwire ABORT (no advance/materialize) ──"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
prompt="$(cat)"; prop="$(printf '%s' "$prompt" | grep -oE '/[^ ]*/proposals/[^ ]+\.json' | head -1)"
[ -n "$prop" ] && printf '{"memories":[{"slug":"rok","type":"feedback","description":"d","body":"b","why":"w"}]}' > "$prop"
mkdir -p "$PENDING_MEM"; printf 'x\n' > "$PENDING_MEM/intruder.md"   # impossible-zone write (a real reviewer is barred here)
echo '{"is_error":false,"total_cost_usd":0}'
S
chmod +x "$sbin/claude"
seed; mkslice; rm -f "$STATE_DIR/sT.line"
PENDING_MEM="$PENDING_MEM" PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sT "$tmp" 1 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sT.line" ]&&echo adv||echo none)" none "reviewer: pending-zone write → NOT advanced"
ok "$([ -f "$memdir/rok.md" ]&&echo mat||echo none)" none "reviewer: pending-zone write → NOT materialized (aborted)"

echo "── reviewer: memory-global BODY write is NOT a zone hit (proceeds) ──"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
prompt="$(cat)"; prop="$(printf '%s' "$prompt" | grep -oE '/[^ ]*/proposals/[^ ]+\.json' | head -1)"
[ -n "$prop" ] && printf '{"memories":[{"slug":"rok2","type":"feedback","description":"d","body":"b","why":"w"}]}' > "$prop"
printf -- '---\nname: bodywrite\ndescription: ordinary external body\nmetadata:\n  type: project\n---\nx\n' > "$LOOP_HOME/memory-global/bodywrite.md"
echo '{"is_error":false,"total_cost_usd":0}'
S
chmod +x "$sbin/claude"
seed; mkslice; rm -f "$STATE_DIR/sB.line"
PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sB "$tmp" 2 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sB.line" ]&&echo adv||echo none)" adv "reviewer: body write is NOT a zone hit → review proceeds (advanced)"

echo "── miner: skills-zone write in window → ABORT (nothing staged) ──"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
mkdir -p "$PENDING_SKILLS/sneaky"; printf 'x\n' > "$PENDING_SKILLS/sneaky/SKILL.md"   # impossible-zone
echo '{"is_error":false}'
S
chmod +x "$sbin/claude"
seed
PENDING_SKILLS="$PENDING_SKILLS" PATH="$sbin:$PATH" SKILL_MINER_ONLY_IF_CHANGED=0 LOOP_MODE=active bash "$L/bin/mine-skills.sh" >/dev/null 2>&1
# the intruder file exists (evidence-only, not reverted) but the miner aborted — assert it logged the anomaly
ok "$(grep -c 'ANOMALY' "$LOG" 2>/dev/null | grep -qv '^0$' && echo yes || echo no)" yes "miner: skills-zone change → logged ANOMALY (aborted, nothing blessed)"

echo "── P0-2: reviewer api-ERROR + pending plant → tripwire fires BEFORE the is_err exit (r3 repeat) ──"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
mkdir -p "$PENDING_MEM"; printf 'x\n' > "$PENDING_MEM/errplant.md"   # plant in the impossible zone...
echo '{"is_error":true}'                                             # ...then take the api-error early-exit path
S
chmod +x "$sbin/claude"
seed; mkslice; rm -f "$STATE_DIR/sERR.line"
PENDING_MEM="$PENDING_MEM" PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sERR "$tmp" 5 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sERR.line" ]&&echo adv||echo none)" none "reviewer api-error + plant → NOT advanced"
ok "$(grep -q 'session=sERR.*ANOMALY' "$LOG" 2>/dev/null && echo yes||echo no)" yes "reviewer api-error + plant → ANOMALY logged (tripwire runs before the is_err exit)"

echo "── P0-2: miner no-proposal + skills plant → tripwire fires BEFORE the no-proposal exit ──"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
mkdir -p "$PENDING_SKILLS/np"; printf 'x\n' > "$PENDING_SKILLS/np/SKILL.md"   # plant in the impossible zone...
echo '{"is_error":false}'                                                     # ...and write NO proposal (no-proposal exit)
S
chmod +x "$sbin/claude"
seed; : > "$LOG"
PENDING_SKILLS="$PENDING_SKILLS" PATH="$sbin:$PATH" SKILL_MINER_ONLY_IF_CHANGED=0 LOOP_MODE=active bash "$L/bin/mine-skills.sh" >/dev/null 2>&1
ok "$(grep -q 'ANOMALY' "$LOG" 2>/dev/null && echo yes||echo no)" yes "miner no-proposal + plant → ANOMALY logged (tripwire runs before the no-proposal exit)"

echo "── P0-1: worker refuses a TAMPERED profile (extra grant) fail-closed at spawn ──"
seed; mkslice
# add a broader grant to the materialized reviewer profile — realpath prefix still present, but NOT byte-exact
python3 - "$L/state/profiles/reviewer.permissions.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["permissions"]["allow"].append("Write(//etc/**)"); json.dump(d,open(p,"w"))
PY
: > "$LOG"; rm -f "$STATE_DIR/sTAMPER.line" "$memdir/rok.md"
cat > "$sbin/claude" <<'S'
#!/usr/bin/env bash
prop="$(cat | grep -oE '/[^ ]*/proposals/[^ ]+\.json' | head -1)"
[ -n "$prop" ] && printf '{"memories":[{"slug":"rok","type":"feedback","description":"d","body":"b","why":"w"}]}' > "$prop"
echo '{"is_error":false,"total_cost_usd":0}'
S
chmod +x "$sbin/claude"
PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sTAMPER "$tmp" 6 stop >/dev/null 2>&1
ok "$([ -f "$memdir/rok.md" ]&&echo spawned||echo refused)" refused "P0-1: tampered profile → reviewer refuses to spawn (no proposal materialized)"
ok "$([ -f "$STATE_DIR/sTAMPER.line" ]&&echo adv||echo none)" none "P0-1: tampered profile → no watermark advance"
bash "$L/bin/loopctl" reprofile >/dev/null 2>&1   # restore byte-exact for any later use

echo "── garden: .git tamper → r5 GIT-FREE abort BEFORE any git op (planted fsmonitor NEVER fires) ──"
probe="$tmp/fsmon-probe.sh"; sentinel="$tmp/PROBE_FIRED"
printf '#!/usr/bin/env bash\ntouch %q\n' "$sentinel" > "$probe"; chmod +x "$probe"
# CONTROL: prove a modified core.fsmonitor DOES run on a git op in this env (else the test would be vacuous)
seed; rm -f "$sentinel"; printf '[core]\n\tfsmonitor = %q\n' "$probe" >> "$memdir/.git/config"; git -C "$memdir" status >/dev/null 2>&1
ok "$([ -e "$sentinel" ]&&echo fired||echo inert)" fired "control: a modified core.fsmonitor DOES run on a git op here"
# now the real test: gardener stub plants the same helper mid-window → garden must abort git-FREE before its restore
cat > "$sbin/claude" <<STUB
#!/usr/bin/env bash
prompt="\$(cat)"
digest="\$(printf '%s' "\$prompt" | tr '\`' '\n' | grep -oE '^/[^ ]*garden-[0-9][0-9-]*\.md\$' | head -1)"
printf '[core]\n\tfsmonitor = %q\n' "$probe" >> "\$LOOP_HOME/memory-global/.git/config"   # .git tamper (config-helper class)
[ -n "\$digest" ] && echo done > "\$digest"; echo '{"is_error":false}'
STUB
chmod +x "$sbin/claude"
seed; rm -f "$sentinel" "$STATE_DIR/garden.fail"
PATH="$sbin:$PATH" LOOP_ENABLED=1 LOOP_MODE=active bash "$L/bin/garden.sh" scheduled >/dev/null 2>&1
ok "$([ -e "$sentinel" ]&&echo fired||echo safe)" safe "garden: planted fsmonitor NEVER fired (.git abort precedes every git op)"
ok "$([ -f "$STATE_DIR/garden.fail" ]&&echo yes||echo no)" yes "garden: .git tamper → run marked FAILED (git-zone-tamper)"

echo "  (tripwire: $( [ "$rc" = 0 ] && echo ALL GREEN || echo has failures ))"
exit "$rc"