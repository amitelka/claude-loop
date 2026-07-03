#!/usr/bin/env bash
# Gardener-hardening 2a: validate_store (deterministic integrity) + validate-THEN-commit + auto-restore.
# Proves a failed/invalid garden run RESTORES to the clean pre-garden snapshot and NEVER commits corruption
# as HEAD (the manual-rollback trap from the incident), and that the materialize post-write gate quarantines
# an invalid write. Public-safe: temp CLAUDE_CONFIG_DIR + a controlled store + a stub `claude` (the gardener).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rc=0
ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
has(){ case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL  claude-loop install errored"; exit 1; }
export CLAUDE_CONFIG_DIR="$tmp"
L="$tmp/loop"; memdir="$tmp/memory-global"
printf 'LOOP_ENABLED=1\nLOOP_MODE=active\n' > "$L/config.local.sh"   # garden.sh/materialize need the loop enabled + active

# ── PREFLIGHT (kill-switch pattern): resolved store paths MUST be under the temp root, else ABORT ──
eval "$(bash -c ". \"$L/lib.sh\"; printf 'P_MEM=%q\nP_LOG=%q\n' \"\$MEMORY_DIR\" \"\$LOG\"")"
case "$P_MEM" in "$tmp"/*) ;; *) echo "  FATAL preflight: MEMORY_DIR=$P_MEM escapes temp — ABORT"; exit 1;; esac
mkdir -p "$(dirname "$P_LOG")"
echo "  ok    preflight: store paths under temp root"

# ── controlled store: 4 hot (feedback) + 4 cold (reference), as a git repo ──
build_store(){
  rm -rf "$memdir"; mkdir -p "$memdir"
  local s
  for s in h1 h2 h3 h4; do printf -- '---\nname: %s\nmetadata:\n  type: feedback\n---\nbody of %s\n' "$s" "$s" > "$memdir/$s.md"; done
  for s in c1 c2 c3 c4; do printf -- '---\nname: %s\nmetadata:\n  type: reference\n---\nbody of %s\n' "$s" "$s" > "$memdir/$s.md"; done
  { echo "# Memory Index"; echo; for s in h1 h2 h3 h4; do echo "- [$s]($s.md) — desc $s"; done; } > "$memdir/MEMORY.md"
  { echo "# Memory Archive"; echo; for s in c1 c2 c3 c4; do echo "- [$s]($s.md) — desc $s"; done; } > "$memdir/ARCHIVE.md"
  git -C "$memdir" init -q; git -C "$memdir" -c user.email=t@t -c user.name=t add -A
  git -C "$memdir" -c user.email=t@t -c user.name=t commit -q -m base
}
sig(){ find "$memdir" -type f -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}'; }
mhead(){ git -C "$memdir" rev-parse HEAD 2>/dev/null; }
drop_slug(){ local s="$1" t; rm -f "$memdir/$s.md"; for t in MEMORY ARCHIVE; do grep -v "($s.md)" "$memdir/$t.md" > "$memdir/.t" 2>/dev/null && mv "$memdir/.t" "$memdir/$t.md"; done; }

# ═══ PART 1 — UNIT validate_store (call directly) ═══
echo "── Part 1: validate_store unit ──"
# shellcheck disable=SC1090
. "$L/lib.sh" >/dev/null 2>&1
vr(){ validate_store "$memdir" "${1:-}" "${2:-}" 2>/dev/null; }
mkdecl(){ printf '%s' "$1" > "$tmp/decl.json"; echo "$tmp/decl.json"; }   # write a declared-actions.json, echo its path

build_store; ok "$(vr >/dev/null; echo $?)" 0 "clean store → PASS"
build_store; { printf '%s' "$(sed -n '3p' "$memdir/MEMORY.md")"; sed -n '4p' "$memdir/MEMORY.md"; } | tr -d '\n' > "$memdir/.m"; sed -i.bak '3,4d' "$memdir/MEMORY.md"; cat "$memdir/.m" >> "$memdir/MEMORY.md"; rm -f "$memdir/.m" "$memdir/MEMORY.md.bak"
  ok "$(has "$(vr)" malformed-entry)" yes "merged/mangled line → FAIL malformed-entry"
build_store; echo "- [ghost](ghost.md) — no file" >> "$memdir/MEMORY.md"; ok "$(has "$(vr)" orphan-index)" yes "index line w/o file → FAIL orphan-index"
build_store; printf -- '---\nname: loose\n---\nx\n' > "$memdir/loose.md"; ok "$(has "$(vr)" dangling-file)" yes "file in no index → FAIL dangling-file"
build_store; echo "- [c1](c1.md) — dup into hot" >> "$memdir/MEMORY.md"; ok "$(has "$(vr)" dup-index)" yes "slug in both tiers → FAIL dup-index"
# (a) missing / empty index file (empty-glob class)
build_store; rm -f "$memdir/MEMORY.md"; ok "$(has "$(vr)" missing-index)" yes "(a) deleted MEMORY.md → FAIL missing-index"
build_store; : > "$memdir/MEMORY.md"; ok "$(has "$(vr)" empty-index)" yes "(a) truncated MEMORY.md → FAIL empty-index"
# (b) tricky-but-legal descriptions (brackets, parens, em-dashes, backticks, a bare '.md' word) must PASS
build_store
{ echo "# Memory Index"; echo
  echo "- [h1](h1.md) — use \`foo.md\` (not bar) — see [note] and (a](b) edge — em—dash ok"
  echo "- [h2](h2.md) — desc h2"; echo "- [h3](h3.md) — desc h3"; echo "- [h4](h4.md) — desc h4"; } > "$memdir/MEMORY.md"
  ok "$(vr >/dev/null; echo $?)" 0 "(b) tricky-but-legal descriptions → PASS (not over-strict)"

# ── drop check (2b: declared-actions intent + volume ceiling + rule rail); needs pre_rev + declared file ──
build_store; pre="$(mhead)"; drop_slug c1
  ok "$(vr "$pre" "$(mkdecl '[{"slug":"c1","action":"deleted"}]')" >/dev/null; echo $?)" 0 "declared reference prune → PASS"
build_store; pre="$(mhead)"; drop_slug c1
  ok "$(has "$(vr "$pre")" undeclared-drop)" yes "undeclared drop (no declared file) → FAIL (fail-closed, F3)"
build_store; pre="$(mhead)"; drop_slug c1
  ok "$(has "$(vr "$pre" "$(mkdecl '[{"slug":"c2","action":"deleted"}]')")" undeclared-drop)" yes "stale/mismatched declared file (lists c2, dropped c1) → FAIL undeclared-drop"
build_store; pre="$(mhead)"; drop_slug h1
  ok "$(has "$(vr "$pre" "$(mkdecl '[{"slug":"h1","action":"deleted"}]')")" rule-typed-drop)" yes "DECLARED feedback drop → FAIL rule-typed (F1 absolute)"
build_store; pre="$(mhead)"; drop_slug c1; drop_slug c2; drop_slug c3; drop_slug h4
  ok "$(has "$(vr "$pre" "$(mkdecl '[{"slug":"c1"},{"slug":"c2"},{"slug":"c3"},{"slug":"h4"}]')")" too-many-drops)" yes "too-many drops even if ALL declared → FAIL (ceiling, F2)"
build_store; pre="$(mhead)"; drop_slug c1
  ok "$(vr "$pre" "$(mkdecl '[{"slug":"c1","action":"deleted"},{"slug":"c2","action":"deleted"}]')" >/dev/null; echo $?)" 0 "declared-but-not-observed (c2 declared, only c1 dropped) → PASS (harmless WARN)"
build_store; pre="$(mhead)"
  ok "$(vr "$pre" >/dev/null; echo $?)" 0 "(F3) zero drops + no declared file → PASS"

# ═══ PART 2 — INTEGRATION: garden.sh drives a stubbed gardener ═══
echo "── Part 2: garden.sh validate-then-commit / auto-restore ──"
sbin="$tmp/stubbin"; mkdir -p "$sbin"
cat > "$sbin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # consume the prompt
store="$CLAUDE_CONFIG_DIR/memory-global"; digest="$CLAUDE_CONFIG_DIR/loop/log/garden-$(date +%Y-%m-%d).md"
case "${GARDEN_TEST_SCENARIO:-}" in
  clean)    printf '\nappended\n' >> "$store/h1.md"; echo done > "$digest"; echo '{"is_error":false,"total_cost_usd":0}'; exit 0;;
  mangle)   m="$store/MEMORY.md"; { sed -n '3p' "$m" | tr -d '\n'; sed -n '4p' "$m"; } > /tmp/gm.$$; sed -i.bak '3,4d' "$m"; cat /tmp/gm.$$ >> "$m"; rm -f /tmp/gm.$$ "$m.bak"; echo done > "$digest"; echo '{"is_error":false}'; exit 0;;
  untracked) printf -- '---\nname: orphan-new\n---\nx\n' > "$store/orphan-new.md"; m="$store/MEMORY.md"; { sed -n '3p' "$m" | tr -d '\n'; sed -n '4p' "$m"; } > /tmp/gu.$$; sed -i.bak '3,4d' "$m"; cat /tmp/gu.$$ >> "$m"; rm -f /tmp/gu.$$ "$m.bak"; echo done > "$digest"; echo '{"is_error":false}'; exit 0;;
  rcfail)   echo "boom" >&2; exit 1;;
  drop-undeclared) rm -f "$store/c1.md"; grep -v '(c1.md)' "$store/ARCHIVE.md" > "$store/.a" && mv "$store/.a" "$store/ARCHIVE.md"; echo done > "$digest"; echo '{"is_error":false}'; exit 0;;
  drop-declared)   rm -f "$store/c1.md"; grep -v '(c1.md)' "$store/ARCHIVE.md" > "$store/.a" && mv "$store/.a" "$store/ARCHIVE.md"; printf '[{"slug":"c1","action":"deleted","reason":"stale"}]' > "$CLAUDE_CONFIG_DIR/loop/log/garden-declared-$(date +%Y-%m-%d).json"; echo done > "$digest"; echo '{"is_error":false}'; exit 0;;
  *) echo '{"is_error":false}'; exit 0;;
esac
STUB
chmod +x "$sbin/claude"
run_garden(){ GARDEN_TEST_SCENARIO="$1" PATH="$sbin:$PATH" bash "$L/bin/garden.sh" >/dev/null 2>&1; }
idx_fresh(){ [ -f "$L/state/mem-index.json" ] && [ -z "$(find "$memdir" -name '*.md' -newer "$L/state/mem-index.json" 2>/dev/null | head -1)" ] && echo yes || echo no; }

# (i) clean → COMMIT (HEAD advances, success marked, index rebuilt — addition c)
build_store; h0="$(mhead)"; rm -f "$L/state/garden.fail" "$L/state/garden.success"; run_garden clean
ok "$([ "$(mhead)" != "$h0" ] && echo advanced || echo same)" advanced "(i) clean run → COMMIT (HEAD advanced)"
ok "$([ -f "$L/state/garden.success" ] && echo yes || echo no)" yes "(i) garden.success marked"
ok "$(idx_fresh)" yes "(i) derived index REBUILT post-commit (addition c)"

# (ii) mangled index → RESTORE
build_store; pre="$(mhead)"; s0="$(sig)"; rm -f "$L/state/garden.fail"; run_garden mangle
ok "$(mhead)" "$pre" "(ii) mangle → HEAD == pre-garden (no corruption committed)"
ok "$(sig)" "$s0" "(ii) mangle → store byte-identical to pre"
ok "$([ -f "$L/state/garden.fail" ] && echo yes || echo no)" yes "(ii) garden.fail marked"
ok "$([ -f "$L/log/garden-FAILED-$(date +%Y-%m-%d).patch" ] && echo yes || echo no)" yes "(ii) forensic patch written"

# (iii) rc-fail → RESTORE regardless of content
build_store; pre="$(mhead)"; s0="$(sig)"; run_garden rcfail
ok "$(mhead)" "$pre" "(iii) rc!=0 → HEAD == pre-garden"
ok "$(sig)" "$s0" "(iii) rc!=0 → store byte-identical to pre"

# (iv) untracked survivor (gardener wrote a new file, run failed) → git clean -fd removed it
build_store; pre="$(mhead)"; s0="$(sig)"; run_garden untracked
ok "$([ -e "$memdir/orphan-new.md" ] && echo present || echo gone)" gone "(iv) untracked orphan removed by clean -fd"
ok "$(git -C "$memdir" status --porcelain | wc -l | tr -d ' ')" 0 "(iv) worktree clean after restore (no untracked survivors)"
ok "$(sig)" "$s0" "(iv) store byte-identical to pre"

# (v) undeclared drop → RESTORE ; (vi) declared drop → COMMIT (the 2b intent path end-to-end)
build_store; pre="$(mhead)"; s0="$(sig)"; rm -f "$L/state/garden.fail"; run_garden drop-undeclared
ok "$(mhead)" "$pre" "(v) UNDECLARED drop → HEAD == pre-garden (restored)"
ok "$(sig)" "$s0" "(v) undeclared drop → store byte-identical to pre"
build_store; h0="$(mhead)"; rm -f "$L/state/garden.fail" "$L/state/garden.success"; run_garden drop-declared
ok "$([ "$(mhead)" != "$h0" ] && echo advanced || echo same)" advanced "(vi) DECLARED drop → COMMIT (HEAD advanced)"
ok "$([ -e "$memdir/c1.md" ] && echo present || echo gone)" gone "(vi) declared drop applied (c1 removed + committed)"

# ═══ PART 3 — MATERIALIZE post-write gate (addition d) ═══
echo "── Part 3: materialize post-write integrity gate ──"
build_store
valid_prop="$tmp/valid.json"; printf '{"memories":[{"slug":"newmemo","type":"feedback","description":"d","body":"b","why":"w"}]}' > "$valid_prop"
LOOP_MODE=active PATH="$sbin:$PATH" bash "$L/bin/materialize.sh" "$valid_prop" sess "$tmp" >/dev/null 2>&1
ok "$([ -f "$memdir/newmemo.md" ] && grep -q '(newmemo.md)' "$memdir/MEMORY.md" && echo yes || echo no)" yes "(d) valid write → committed (file + index line)"
ok "$(vr >/dev/null; echo $?)" 0 "(d) store still valid after a good write"
# induce invalid: the gardener sidecar can't; simulate a proposal whose write leaves a dangling ref by pre-corrupting,
# then a valid write should be quarantined because the post-write store is invalid.
build_store; echo "- [ghostx](ghostx.md) — no file" >> "$memdir/MEMORY.md"   # pre-existing orphan → any write's post-state is invalid
git -C "$memdir" -c user.email=t@t -c user.name=t commit -aqm corrupt
LOOP_MODE=active PATH="$sbin:$PATH" bash "$L/bin/materialize.sh" "$valid_prop" sess2 "$tmp" >/dev/null 2>&1
ok "$([ -f "$memdir/newmemo.md" ] && echo committed || echo reverted)" reverted "(d) invalid post-write state → write REVERTED (no commit)"
ok "$(ls "$L/pending/memories"/quarantine-sess2-*.json >/dev/null 2>&1 && echo yes || echo no)" yes "(d) proposal QUARANTINED to pending/"
ok "$(grep -c 'materialize: quarantine' "$P_LOG" 2>/dev/null | tr -d ' ' | grep -qv '^0$' && echo yes || echo no)" yes "(d) doctor-visible quarantine tag logged"

# ═══ PART 4 — INCIDENT regression fixture (mangled line + dropped slug together) ═══
echo "── Part 4: incident replay ──"
cat > "$sbin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
store="$CLAUDE_CONFIG_DIR/memory-global"; digest="$CLAUDE_CONFIG_DIR/loop/log/garden-$(date +%Y-%m-%d).md"
m="$store/MEMORY.md"; { sed -n '3p' "$m" | tr -d '\n'; sed -n '4p' "$m"; } > /tmp/gi.$$; sed -i.bak '3,4d' "$m"; cat /tmp/gi.$$ >> "$m"; rm -f /tmp/gi.$$ "$m.bak"
rm -f "$store/c1.md"; grep -v '(c1.md)' "$store/ARCHIVE.md" > "$store/.a" && mv "$store/.a" "$store/ARCHIVE.md"
echo done > "$digest"; echo '{"is_error":false}'; exit 0
STUB
chmod +x "$sbin/claude"
build_store; pre="$(mhead)"; s0="$(sig)"; rm -f "$L/state/garden.fail"; run_garden incident
ok "$(mhead)" "$pre" "incident (mangle+drop) → HEAD == pre-garden"
ok "$(sig)" "$s0" "incident → store byte-identical to pre (fully recovered)"
ok "$([ -f "$L/state/garden.fail" ] && echo yes || echo no)" yes "incident → run marked FAILED"

exit "$rc"
