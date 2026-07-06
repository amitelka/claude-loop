#!/usr/bin/env bash
# External-memory ingress (#16): peer agents write memory bodies directly into memory-global; the loop must
# reconcile/commit/preserve them deterministically at every store-mutating entry, kill the old commit-as-is
# poison path, and never advance the watermark on a deferral/park. Public-safe: temp CLAUDE_CONFIG_DIR + a
# controlled store + a stub `claude`; no private data, no real model calls.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_setup.sh"
rc=0
ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL  claude-loop install errored"; exit 1; }
export CLAUDE_CONFIG_DIR="$tmp"
L="$tmp/loop"; memdir="$LOOP_HOME/memory-global"
printf 'LOOP_ENABLED=1\nLOOP_MODE=active\n' > "$L/config.local.sh"

# PREFLIGHT (kill-switch pattern): resolved store paths MUST be under the temp root, else ABORT.
eval "$(bash -c ". \"$L/lib.sh\"; printf 'P_MEM=%q\nP_LOG=%q\nP_Q=%q\n' \"\$MEMORY_DIR\" \"\$LOG\" \"\$QUARANTINE_DIR\"")"
case "$P_MEM" in "$tmp"/*) ;; *) echo "  FATAL preflight: MEMORY_DIR=$P_MEM escapes temp — ABORT"; exit 1;; esac
case "$P_Q"   in "$tmp"/*) ;; *) echo "  FATAL preflight: QUARANTINE_DIR=$P_Q escapes temp — ABORT"; exit 1;; esac
mkdir -p "$(dirname "$P_LOG")"
echo "  ok    preflight: store + quarantine paths under temp root"

# shellcheck disable=SC1090
. "$L/lib.sh" >/dev/null 2>&1

mkbody(){ printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  node_type: memory\n  type: %s\n---\n%s\n' "$1" "$2" "$3" "body-$1" > "$memdir/$1.md"; }
seed(){ rm -rf "$memdir"; mkdir -p "$memdir"
  mkbody existing-rule "an existing feedback rule" feedback
  mkbody existing-proj "an existing project note" project
  printf '%s\n' "${HOTLINES:-- [existing-rule](existing-rule.md) — an existing feedback rule}" > "$memdir/MEMORY.md"
  printf '%s\n' "${COLDLINES:-- [existing-proj](existing-proj.md) — an existing project note}" > "$memdir/ARCHIVE.md"
  git -C "$memdir" init -q; git -C "$memdir" -c user.email=t@t -c user.name=t add -A
  git -C "$memdir" -c user.email=t@t -c user.name=t commit -qm seed; rm -rf "$P_Q"; }
chk(){ validate_store "$memdir" >/dev/null 2>&1 && echo GREEN || echo "FAIL:$(validate_store "$memdir" 2>/dev/null)"; }
head_at(){ git -C "$memdir" rev-parse HEAD 2>/dev/null; }
lastmsg(){ git -C "$memdir" log -1 --format=%s 2>/dev/null; }

echo "── Part 1: ingest_external unit ──"
seed; mkbody peer-note "a peer project memory" project; st="$(ingest_external)"
ok "$st" ingested "frozen-3c: valid body no index line → status ingested"
ok "$(chk)" GREEN "frozen-3c: store green"
ok "$(grep -c 'peer-note.md' "$memdir/ARCHIVE.md")" 1 "frozen-3c: routed COLD (type:project)"
ok "$(grep -c 'peer-note.md' "$memdir/MEMORY.md")" 0 "frozen-3c: NOT hot"
ok "$(git -C "$memdir" status --porcelain|wc -l|tr -d ' ')" 0 "frozen-3c: tree clean after commit"
ok "$(lastmsg|grep -c '^external-memory-ingress')" 1 "frozen-3c: external-memory-ingress commit"

seed; printf 'garbage\n' > "$memdir/Plan IMPL.md"; mkbody good-note "a good rule" feedback; st="$(ingest_external)"
ok "$st" ingested "illegal-slug incident: status ingested"
ok "$([ -e "$memdir/Plan IMPL.md" ]&&echo present||echo gone)" gone "illegal-slug: uppercase-IMPL junk removed"
ok "$(find "$P_Q" -name 'Plan IMPL.md'|wc -l|tr -d ' ')" 1 "illegal-slug: junk quarantined (recoverable)"
ok "$(grep -c 'good-note.md' "$memdir/MEMORY.md")" 1 "illegal-slug: coexisting valid body lands"
ok "$(chk)" GREEN "illegal-slug: store green"

seed; rm "$memdir/existing-rule.md"; st="$(ingest_external)"
ok "$([ -f "$memdir/existing-rule.md" ]&&echo y||echo n)" y "peer-deletion (rule-typed feedback): body RESTORED, not honored (F1)"
ok "$(grep -c 'existing-rule.md' "$memdir/MEMORY.md")" 1 "peer-deletion: index line intact"
ok "$(chk)" GREEN "peer-deletion: store green"

seed; printf 'CORRUPTED no frontmatter\n' > "$memdir/existing-proj.md"; st="$(ingest_external)"   # tracked body broken in worktree
ok "$(grep -c 'body-existing-proj' "$memdir/existing-proj.md")" 1 "tracked-BROKEN: HEAD good body RESTORED (git checkout, not rm)"
ok "$(find "$P_Q" -type f -name 'existing-proj.md'|wc -l|tr -d ' ')" 1 "tracked-BROKEN: dirty copy parked (recoverable)"
ok "$(chk)" GREEN "tracked-BROKEN: store green"

seed; printf 'no frontmatter\n' > "$memdir/junk-untracked.md"; st="$(ingest_external)"
ok "$([ -e "$memdir/junk-untracked.md" ]&&echo present||echo gone)" gone "untracked-BROKEN: parked + removed"
ok "$(chk)" GREEN "untracked-BROKEN: store green"

seed; grep -v 'existing-proj.md' "$memdir/ARCHIVE.md" > "$memdir/.a" && mv "$memdir/.a" "$memdir/ARCHIVE.md"; st="$(ingest_external)"   # index-only: peer removed a pointer line
ok "$(grep -c 'existing-proj.md' "$memdir/ARCHIVE.md")" 1 "index-only dirt: removed pointer for a live body → RESTORED"
ok "$(chk)" GREEN "index-only dirt: store green"

COLDLINES='- [existing-proj](existing-proj.md) — CUSTOM operator hook KEEP' seed
mkbody existing-proj "a totally new description" project; st="$(ingest_external)"   # valid edit, correct-tier custom line
ok "$(grep -c 'CUSTOM operator hook KEEP' "$memdir/ARCHIVE.md")" 1 "preserve-line: operator hook text survives byte-identical"
ok "$(grep -c 'totally new description' "$memdir/ARCHIVE.md")" 0 "preserve-line: NOT regenerated from body description"

seed; before="$(head_at)"; st="$(ingest_external)"
ok "$st" clean "clean tree → status clean"
ok "$(head_at)" "$before" "clean tree → no commit"

echo "── Part 2: materialize integration (exit contract, explicit-path staging) ──"
valid='{"memories":[{"slug":"newmemo","type":"feedback","description":"d","body":"b","why":"w"}]}'
seed; printf 'garbage\n' > "$memdir/Bad IMPL.md"; printf '%s' "$valid" > "$tmp/p.json"     # frozen-1: bad external + valid proposal
LOOP_MODE=active bash "$L/bin/materialize.sh" "$tmp/p.json" sessA "$tmp" >/dev/null 2>&1; mrc=$?
ok "$mrc" 0 "frozen-1: materialize exit landed(0)"
ok "$([ -f "$memdir/newmemo.md" ]&&echo y||echo n)" y "frozen-1: reviewer proposal LANDED"
ok "$([ -e "$memdir/Bad IMPL.md" ]&&echo present||echo gone)" gone "frozen-1: bad external file quarantined at entry-ingress"
ok "$(chk)" GREEN "frozen-1: store green"

seed; mkdir -p "$STATE_DIR/store.lock"; echo "holder $$ $(date +%s)" > "$STATE_DIR/store.lock/owner"   # busy: live pid → no dead-pid/stale steal
before="$(head_at)"; printf '%s' "$valid" > "$tmp/p2.json"
MATERIALIZE_LOCK_TRIES=1 MATERIALIZE_LOCK_SLEEP=0 LOOP_MODE=active bash "$L/bin/materialize.sh" "$tmp/p2.json" sessB "$tmp" >/dev/null 2>&1; mrc=$?
ok "$mrc" 20 "deferred-exit-contract: store busy → exit deferred(20)"
ok "$([ -f "$memdir/newmemo.md" ]&&echo wrote||echo none)" none "deferred: no write while busy"
ok "$(head_at)" "$before" "deferred: no commit while busy"
rm -rf "$STATE_DIR/store.lock"

seed; printf '%s' "$valid" > "$tmp/p3.json"   # explicit-path staging (P0-c): materialize's commit == EXACTLY its own written paths
LOOP_MODE=active bash "$L/bin/materialize.sh" "$tmp/p3.json" sessC "$tmp" >/dev/null 2>&1
committed="$(git -C "$memdir" show --name-only --format= HEAD 2>/dev/null | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
ok "$committed" "MEMORY.md newmemo.md " "explicit-path staging (P0-c): commit == exactly {hot index + written body}, no add -A over-commit (ARCHIVE unchanged → absent)"

echo "── Part 3: review integration (in-window park, entry-skip) — stubbed reviewer ──"
sbin="$tmp/stubbin"; mkdir -p "$sbin"
cat > "$sbin/claude" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
prop="$(printf '%s' "$prompt" | grep -oE '/[^ ]*/proposals/[^ ]+\.json' | head -1)"
[ -n "$prop" ] && printf '{"memories":[{"slug":"revmemo","type":"feedback","description":"d","body":"b","why":"w"}]}' > "$prop"
# IN-WINDOW scenario: a peer writes a memory body straight into memory-global DURING the reviewer run
if [ "${REVIEW_TEST_INWINDOW:-0}" = 1 ]; then
  printf -- '---\nname: inwindow-peer\ndescription: wrote mid-window\nmetadata:\n  type: project\n---\nx\n' > "$LOOP_HOME/memory-global/inwindow-peer.md"
fi
# TWO-DIR laundering scenario: reviewer writes a valid-format memory into memory-global AND touches pending in one run
if [ "${REVIEW_TEST_TWODIR:-0}" = 1 ]; then
  printf -- '---\nname: laundry\ndescription: laundering attempt\nmetadata:\n  type: feedback\n---\nx\n' > "$LOOP_HOME/memory-global/laundry.md"
  mkdir -p "$CLAUDE_CONFIG_DIR/loop/pending/memories"; printf 'x\n' > "$CLAUDE_CONFIG_DIR/loop/pending/memories/sneak.md"
fi
echo '{"is_error":false,"total_cost_usd":0}'
STUB
chmod +x "$sbin/claude"
mkslice(){ printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}' > "$tmp/slice.jsonl"; }

seed; mkslice; rm -f "$STATE_DIR/sessD.line"
REVIEW_TEST_INWINDOW=1 PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sessD "$tmp" 42 stop >/dev/null 2>&1
ok "$(git -C "$memdir" log --format=%s 2>/dev/null | grep -c 'reviewer-anomaly')" 0 "in-window: NO reviewer-anomaly commit (poison path deleted)"
# #23: no reviewer WINDOW guard — a real reviewer can't write the store (platform-scoped to proposals/); the only
# in-window store writer is an external process, which #16 treats as first-class. A VALID body is ACCEPTED
# (reconciled/ingested), not reverted. (No pending/skills/.git touched here → the tripwire does not fire.)
ok "$([ -e "$memdir/inwindow-peer.md" ]&&echo present||echo gone)" present "in-window: valid external body ACCEPTED (ingested first-class, #23 — not reverted)"
ok "$(git -C "$memdir" ls-files inwindow-peer.md 2>/dev/null | grep -q . && echo tracked || echo untracked)" tracked "in-window: accepted body committed (indexed + tracked)"
ok "$([ -f "$memdir/revmemo.md" ]&&echo y||echo n)" y "in-window: reviewer proposal still materialized (proceeded)"
ok "$(chk)" GREEN "in-window: store green"
ok "$(cat "$STATE_DIR/sessD.line" 2>/dev/null)" 42 "in-window: watermark advanced (materialize landed)"

seed; mkslice; rm -f "$STATE_DIR/sessE.line"
mkdir -p "$STATE_DIR/store.lock"; echo "holder $$ $(date +%s)" > "$STATE_DIR/store.lock/owner"    # busy at entry (live pid)
REVIEW_TEST_INWINDOW=0 PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sessE "$tmp" 99 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sessE.line" ]&&echo advanced||echo none)" none "entry-skip: store busy at entry → watermark NOT advanced"
ok "$(grep -c 'store busy at entry' "$P_LOG" 2>/dev/null|tr -d ' '|grep -qv '^0$'&&echo yes||echo no)" yes "entry-skip: logged skip-before-spend"
rm -rf "$STATE_DIR/store.lock"

echo "── Part 4: re-verify findings (P1-1 laundering, P1-2 junk, backstop, held-lock, restore-leg) ──"
# P1-2: non-.md and subdir dirt (unit)
seed; printf 'x\n' > "$memdir/notes.txt"; mkdir -p "$memdir/sub"; printf 'x\n' > "$memdir/sub/x.md"; st="$(ingest_external)"
ok "$([ -e "$memdir/notes.txt" ]&&echo present||echo gone)" gone "P1-2: non-.md junk quarantined+removed"
ok "$([ -e "$memdir/sub/x.md" ]&&echo present||echo gone)" gone "P1-2: subdir .md junk quarantined+removed"
ok "$(chk)" GREEN "P1-2: store green after junk removal"

# (v) HEAD-invalid → review entry skip (backstop), no spend/advance
seed; echo "- [ghostzz](ghostzz.md) — no file" >> "$memdir/MEMORY.md"; git -C "$memdir" -c user.email=t@t -c user.name=t commit -aqm corrupt >/dev/null
mkslice; rm -f "$STATE_DIR/sessH.line"
PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sessH "$tmp" 7 stop >/dev/null 2>&1
ok "$([ -f "$memdir/revmemo.md" ]&&echo spent||echo skipped)" skipped "HEAD-invalid backstop: review skipped before reviewer spend"
ok "$([ -f "$STATE_DIR/sessH.line" ]&&echo advanced||echo none)" none "HEAD-invalid: watermark NOT advanced"
ok "$(grep -c 'store INVALID (committed)' "$P_LOG" 2>/dev/null|tr -d ' '|grep -qv '^0$'&&echo yes||echo no)" yes "HEAD-invalid: logged skip"

# (i) P1-1 two-dir (#23): an external process writes a store body (laundry) AND touches pending (sneak) in one
# window. The PENDING touch is an impossible-zone change → the tripwire ABORTS the review (no materialize, no
# advance). The body write is NOT reverted (no window guard) but never rode a review blessing — it is left for
# the next entry-ingress to reconcile as an ordinary external write (valid → accepted first-class).
seed; mkslice; rm -f "$STATE_DIR/sessT.line"
REVIEW_TEST_TWODIR=1 PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sessT "$tmp" 5 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sessT.line" ]&&echo advanced||echo none)" none "P1-1 two-dir: pending touched → tripwire ABORT, watermark NOT advanced"
ok "$(git -C "$memdir" log --format=%s 2>/dev/null|grep -c laundry)" 0 "P1-1 two-dir: laundry NOT committed by the aborted review (no materialize ran)"
st="$(ingest_external)"; ok "$st" ingested "P1-1 two-dir: NEXT entry-ingress reconciles the valid body as an ordinary external write (accepted, not laundered-via-review)"
ok "$(chk)" GREEN "P1-1 two-dir: store green after reconcile"

# (ii) lock-shrink (#23): materialize ALWAYS acquires its OWN store lock (the LOOP_STORE_LOCK_HELD parent-passthrough
# is gone — the reviewer now releases the lock before the model run, so nothing holds it into materialize).
seed; printf '%s' "$valid" > "$tmp/ph.json"
LOOP_MODE=active bash "$L/bin/materialize.sh" "$tmp/ph.json" sessLH "$tmp" >/dev/null 2>&1; mrc=$?
ok "$mrc" 0 "materialize: lands standalone (acquires own lock, re-ingests, writes)"
ok "$([ -f "$memdir/newmemo.md" ]&&echo y||echo n)" y "materialize: write committed"
ok "$([ -d "$STATE_DIR/store.lock" ]&&echo held||echo released)" released "materialize: released its own store lock (no leak)"
# under a FOREIGN-held lock materialize DEFERS (rc 20) — no self-deadlock, no partial write
seed; printf '%s' "$valid" > "$tmp/ph.json"
mkdir -p "$STATE_DIR/store.lock"; echo "foreign $$ $(date +%s)" > "$STATE_DIR/store.lock/owner"
MATERIALIZE_LOCK_TRIES=1 MATERIALIZE_LOCK_SLEEP=0 LOOP_MODE=active bash "$L/bin/materialize.sh" "$tmp/ph.json" sessLH2 "$tmp" >/dev/null 2>&1; mrc=$?
ok "$mrc" 20 "materialize: DEFERS under a foreign-held lock (no self-deadlock)"
ok "$([ -f "$memdir/newmemo.md" ]&&echo y||echo n)" n "materialize: nothing written while deferred"
rm -rf "$STATE_DIR/store.lock"

# (iii) garden restore-leg: an untracked peer write during a FAILED garden window is preserved before the revert
cat > "$sbin/claude" <<'GSTUB'
#!/usr/bin/env bash
prompt="$(cat)"; store="$LOOP_HOME/memory-global"
digest="$(printf '%s' "$prompt" | tr '`' '\n' | grep -oE '^/[^ ]*garden-[0-9][0-9-]*\.md$' | head -1)"
printf -- '---\nname: swept-peer\ndescription: peer wrote during garden window\nmetadata:\n  type: project\n---\nx\n' > "$store/swept-peer.md"
sed -i.bak '1s/$/ - [x](x.md) — mangled/' "$store/MEMORY.md" 2>/dev/null; rm -f "$store/MEMORY.md.bak"
[ -n "$digest" ] && echo done > "$digest"; echo '{"is_error":false}'
GSTUB
chmod +x "$sbin/claude"
seed; rm -f "$STATE_DIR/garden.fail"
PATH="$sbin:$PATH" LOOP_ENABLED=1 LOOP_MODE=active bash "$L/bin/garden.sh" scheduled >/dev/null 2>&1
ok "$(find "$P_Q"/garden-swept-* -name 'swept-peer.md' 2>/dev/null|wc -l|tr -d ' ')" 1 "garden restore-leg: untracked peer write preserved in quarantine"
ok "$([ -e "$memdir/swept-peer.md" ]&&echo present||echo reverted)" reverted "garden restore-leg: swept-peer reverted from the store"
ok "$(chk)" GREEN "garden restore-leg: store green after restore"

echo "── Part 5: xhigh NO-SHIP fixes (P0-1 init, P0-2 api-err guard, P0-3 strip rc, P2 fence, P1-a/b) ──"
# P0-1: FRESH no-git store carrying junk + orphan pointer + valid bodies → init must NOT add-A; junk never baselined
rm -rf "$memdir"; mkdir -p "$memdir"
mkbody freshhot "a fresh feedback rule" feedback
mkbody freshcold "a fresh project note" project
printf -- '- [ghost](ghost.md) — orphan pointer, no body\n' > "$memdir/MEMORY.md"
printf 'JUNK not a memory\n' > "$memdir/Bad IMPL.md"
st="$(ingest_external)"
ok "$([ -e "$memdir/Bad IMPL.md" ]&&echo present||echo gone)" gone "P0-1: fresh no-git — illegal junk parked (NOT add-A committed as baseline)"
ok "$(grep -c 'freshhot.md' "$memdir/MEMORY.md")" 1 "P0-1: fresh — valid hot body committed"
ok "$(grep -c 'freshcold.md' "$memdir/ARCHIVE.md")" 1 "P0-1: fresh — valid cold body committed"
ok "$(grep -c 'ghost.md' "$memdir/MEMORY.md")" 0 "P0-1: fresh — orphan pointer stripped"
ok "$(chk)" GREEN "P0-1: fresh — store green"
ok "$(git -C "$memdir" log --all --format= --name-only 2>/dev/null | grep -c 'Bad IMPL')" 0 "P0-1: junk never entered ANY commit (init add-A gone)"

# P0-3: single-entry index strip works + no temp litter (grep -v rc1 = success)
seed
before_hot="$(cat "$memdir/MEMORY.md")"
mem_strip_index_lines existing-rule    # MEMORY.md had exactly one line → grep -v yields 0 lines (rc1)
ok "$(grep -c 'existing-rule.md' "$memdir/MEMORY.md")" 0 "P0-3: single-entry strip removed the line (mv ran despite grep rc1)"
ok "$(ls "$memdir"/*.strip.* 2>/dev/null | wc -l | tr -d ' ')" 0 "P0-3: no .strip.\$\$ temp litter"

# P2: a `description:` line inside the BODY prose must NOT be read as the frontmatter pointer text
seed
printf -- '---\nname: p2body\ndescription: REAL frontmatter desc\nmetadata:\n  type: project\n---\nSome prose then a line:\ndescription: FAKE body-line desc\n' > "$memdir/p2body.md"
st="$(ingest_external)"
ok "$(grep -c 'REAL frontmatter desc' "$memdir/ARCHIVE.md")" 1 "P2: pointer uses the FRONTMATTER description"
ok "$(grep -c 'FAKE body-line desc' "$memdir/ARCHIVE.md")" 0 "P2: body-prose description: NOT used as pointer text"

# P1-a: garden HEAD-invalid backstop → skip, no spend (gardener stub must NOT be invoked)
cat > "$sbin/claude" <<'GSTUB2'
#!/usr/bin/env bash
touch "$CLAUDE_CONFIG_DIR/loop/state/GARDEN_WAS_CALLED"
prompt="$(cat)"; digest="$(printf '%s' "$prompt" | tr '`' '\n' | grep -oE '^/[^ ]*garden-[0-9][0-9-]*\.md$' | head -1)"
[ -n "$digest" ] && echo done > "$digest"; echo '{"is_error":false}'
GSTUB2
chmod +x "$sbin/claude"
seed; echo "- [ghostzz](ghostzz.md) — no file" >> "$memdir/MEMORY.md"; git -C "$memdir" -c user.email=t@t -c user.name=t commit -aqm corrupt >/dev/null
rm -f "$STATE_DIR/GARDEN_WAS_CALLED" "$STATE_DIR/garden.fail"
PATH="$sbin:$PATH" LOOP_ENABLED=1 LOOP_MODE=active bash "$L/bin/garden.sh" scheduled >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/GARDEN_WAS_CALLED" ]&&echo spent||echo skipped)" skipped "P1-a: garden HEAD-invalid → skipped before gardener spend"

# P0-2: review api-error must still run the in-window guard (park) BEFORE exiting
cat > "$sbin/claude" <<'RSTUB2'
#!/usr/bin/env bash
printf -- '---\nname: errwrite\ndescription: injected mid-window then errored\nmetadata:\n  type: project\n---\nx\n' > "$LOOP_HOME/memory-global/errwrite.md"
echo '{"is_error":true}'
RSTUB2
chmod +x "$sbin/claude"
seed; mkslice; rm -f "$STATE_DIR/sessAE.line"
PATH="$sbin:$PATH" LOOP_MODE=active bash "$L/bin/review.sh" "$tmp/slice.jsonl" sessAE "$tmp" 3 stop >/dev/null 2>&1
ok "$([ -f "$STATE_DIR/sessAE.line" ]&&echo advanced||echo none)" none "P0-2: api-error → review aborted, watermark NOT advanced"
ok "$(git -C "$memdir" ls-files errwrite.md 2>/dev/null|grep -q .&&echo committed||echo untracked)" untracked "P0-2: errwrite NOT committed by the errored review (materialize never ran)"
st="$(ingest_external)"; ok "$st" ingested "P0-2: the valid body is reconciled as an ordinary external write next entry (accepted, #23)"

# P1-b (#23): the miner writes a store body but produces no proposal. It stages/commits nothing itself (no
# store-write path); the valid body is left for the next entry-ingress to reconcile as an ordinary external write.
cat > "$sbin/claude" <<'MSTUB'
#!/usr/bin/env bash
printf -- '---\nname: minerinj\ndescription: miner injected\nmetadata:\n  type: feedback\n---\nx\n' > "$LOOP_HOME/memory-global/minerinj.md"
echo '{"is_error":false}'   # no proposal written → no-proposal exit
MSTUB
chmod +x "$sbin/claude"
seed
PATH="$sbin:$PATH" SKILL_MINER_ONLY_IF_CHANGED=0 LOOP_MODE=active bash "$L/bin/mine-skills.sh" >/dev/null 2>&1
ok "$(git -C "$memdir" ls-files minerinj.md 2>/dev/null|grep -q .&&echo committed||echo untracked)" untracked "P1-b: miner committed nothing to the store (no proposal); body left untracked"
st="$(ingest_external)"; ok "$st" ingested "P1-b: valid body reconciled next entry (accepted first-class, #23)"


echo "  (ingress: $( [ "$rc" = 0 ] && echo ALL GREEN || echo has failures ))"
exit "$rc"
