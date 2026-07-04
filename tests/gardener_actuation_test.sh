#!/usr/bin/env bash
# Declared-actions ACTUATION (P1): the LLM gardener has no delete tool, so bash actuates its DECLARED
# deletes/merges (index line + body) BEFORE validate_store — validate-the-declaration-FIRST (schema/rule-typed/
# ceiling/merge-target), idempotent delete-if-present, phantom=warn+skip. Proves the gardener can prune/merge
# again while the bash-vector stays closed (LLM never deletes; bash rm's only from a validated declaration).
# Instrument: the test STUBS the LLM's outputs (declared-actions.json + any index/body edits) and exercises the
# REAL actuate_declared + validate_store code path. Public-safe: temp CLAUDE_CONFIG_DIR + controlled store.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rc=0
ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }
has(){ case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

CLAUDE_CONFIG_DIR="$tmp" bash "$repo/claude-loop" install >/dev/null 2>&1 || { echo "  FAIL  claude-loop install errored"; exit 1; }
export CLAUDE_CONFIG_DIR="$tmp"
L="$tmp/loop"; memdir="$tmp/memory-global"
printf 'LOOP_ENABLED=1\nLOOP_MODE=active\n' > "$L/config.local.sh"

eval "$(bash -c ". \"$L/lib.sh\"; printf 'P_MEM=%q\nP_LOG=%q\n' \"\$MEMORY_DIR\" \"\$LOG\"")"
case "$P_MEM" in "$tmp"/*) ;; *) echo "  FATAL preflight: MEMORY_DIR=$P_MEM escapes temp — ABORT"; exit 1;; esac
mkdir -p "$(dirname "$P_LOG")"
# shellcheck disable=SC1090
. "$L/lib.sh" >/dev/null 2>&1

# controlled store: h1-h4 feedback (rule-class), c1-c6 reference — as a git repo
build_store(){
  rm -rf "$memdir"; mkdir -p "$memdir"; local s
  for s in h1 h2 h3 h4; do printf -- '---\nname: %s\nmetadata:\n  type: feedback\n---\nbody of %s\n' "$s" "$s" > "$memdir/$s.md"; done
  for s in c1 c2 c3 c4 c5 c6; do printf -- '---\nname: %s\nmetadata:\n  type: reference\n---\nbody of %s\n' "$s" "$s" > "$memdir/$s.md"; done
  { echo "# Memory Index"; echo; for s in h1 h2 h3 h4; do echo "- [$s]($s.md) — desc $s"; done; } > "$memdir/MEMORY.md"
  { echo "# Memory Archive"; echo; for s in c1 c2 c3 c4 c5 c6; do echo "- [$s]($s.md) — desc $s"; done; } > "$memdir/ARCHIVE.md"
  git -C "$memdir" init -q; git -C "$memdir" -c user.email=t@t -c user.name=t add -A; git -C "$memdir" -c user.email=t@t -c user.name=t commit -q -m base
}
mhead(){ git -C "$memdir" rev-parse HEAD 2>/dev/null; }
mkdecl(){ printf '%s' "$1" > "$tmp/decl.json"; echo "$tmp/decl.json"; }
fpresent(){ [ -f "$memdir/$1.md" ] && echo yes || echo no; }
inindex(){ grep -qhF "]($1.md)" "$memdir/MEMORY.md" "$memdir/ARCHIVE.md" 2>/dev/null && echo yes || echo no; }
rmline(){ grep -vF "]($1.md)" "$memdir/ARCHIVE.md" > "$memdir/.t" 2>/dev/null && mv "$memdir/.t" "$memdir/ARCHIVE.md"; }   # stub: LLM removed an index line (body stays)
ad(){ actuate_declared "$memdir" "$1" "$2" 2>/dev/null; }
vr(){ validate_store "$memdir" "$1" "$2" 2>/dev/null; }

echo "── declared-actions actuation ──"

# T1 POSITIVE — declared delete + merge actually remove body+index; validate then PASSES
build_store; pre="$(mhead)"
d="$(mkdecl '[{"slug":"c1","action":"deleted"},{"slug":"c2","action":"merged","into":"c3"}]')"
r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 0 "T1 actuate → ok"
ok "$(fpresent c1)/$(fpresent c2)/$(fpresent c3)" "no/no/yes" "T1 c1+c2 removed, c3 (merge target) kept"
ok "$(inindex c1)/$(inindex c2)" "no/no" "T1 c1+c2 index lines removed"
ok "$(vr "$pre" "$d" >/dev/null; echo $?)" 0 "T1 validate_store PASS (observed==declared)"

# T2 RULE-TYPED GUARD (F1) — declaring a feedback-typed drop aborts with zero rm
build_store; pre="$(mhead)"
d="$(mkdecl '[{"slug":"h1","action":"deleted"}]')"; r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 1 "T2 rule-typed declared → abort"
ok "$(has "$r" rule-typed-declared)" yes "T2 reason=rule-typed-declared"
ok "$(fpresent h1)/$(inindex h1)" "yes/yes" "T2 h1 untouched (zero rm)"
# T2b adversarial — mid-run working-tree type-flip must NOT bypass (guard reads PRE-RUN type)
build_store; pre="$(mhead)"; sed -i.bak 's/type: feedback/type: reference/' "$memdir/h1.md"; rm -f "$memdir/h1.md.bak"
d="$(mkdecl '[{"slug":"h1","action":"deleted"}]')"; r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 1 "T2b working-tree type-flip → STILL abort (pre-run snapshot type wins)"
ok "$(fpresent h1)" yes "T2b h1 body untouched"

# T3 CEILING (F2)
build_store; pre="$(mhead)"
d="$(mkdecl '[{"slug":"c1","action":"deleted"},{"slug":"c2","action":"deleted"},{"slug":"c3","action":"deleted"},{"slug":"c4","action":"deleted"}]')"
r="$(GARDEN_MAX_DROPS=3 actuate_declared "$memdir" "$pre" "$d" 2>/dev/null)"; arc=$?
ok "$arc" 1 "T3 over-ceiling (4>3) → abort"
ok "$(has "$r" too-many-declared)" yes "T3 reason=too-many-declared"
ok "$(fpresent c1)" yes "T3 zero rm"

# T4 MERGE-INTO-NOTHING
build_store; pre="$(mhead)"
d="$(mkdecl '[{"slug":"c1","action":"merged","into":"nonexistent"}]')"; r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 1 "T4 merge into missing target → abort"
ok "$(has "$r" merge-into-missing)" yes "T4 reason=merge-into-missing"
ok "$(fpresent c1)" yes "T4 c1 not removed"

# T5 IDEMPOTENT — converges whether or not the LLM pre-removed the index line; safe to re-run
build_store; pre="$(mhead)"; rmline c1   # (a) LLM already removed the index line, body remains
d="$(mkdecl '[{"slug":"c1","action":"deleted"}]')"; ad "$pre" "$d" >/dev/null; arc=$?
ok "$arc" 0 "T5a index-pre-removed → ok"
ok "$(fpresent c1)/$(inindex c1)" "no/no" "T5a converged (body+index gone)"
build_store; pre="$(mhead)"; d="$(mkdecl '[{"slug":"c1","action":"deleted"}]')"; ad "$pre" "$d" >/dev/null; ad "$pre" "$d" >/dev/null; arc=$?   # (b) run twice
ok "$arc" 0 "T5b re-run idempotent → ok (2nd run: phantom skip)"
ok "$(fpresent c1)/$(inindex c1)" "no/no" "T5b body+index gone, no error on re-run"

# T6 UNDECLARED-DROP NOT MASKED — LLM drops an index line but declares nothing → validate_store still catches it
build_store; pre="$(mhead)"; rmline c1; d="$(mkdecl '[]')"; ad "$pre" "$d" >/dev/null; arc=$?
ok "$arc" 0 "T6 empty declaration → actuation no-op ok"
ok "$(fpresent c1)" yes "T6 c1 body NOT actuated (undeclared)"
ok "$(has "$(vr "$pre" "$d")" dangling-file)" yes "T6 validate_store fires dangling-file (unmasked → 2a restore)"

# T7 INVALID SCHEMA → ZERO actuation (pins order: validate declaration BEFORE actuate)
build_store; pre="$(mhead)"; rmline c1   # stub also did an edit; must not matter — schema aborts first
d="$(mkdecl '{"not":"an-array"}')"; r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 1 "T7 invalid schema → abort"
ok "$(has "$r" bad-declared-schema)" yes "T7 reason=bad-declared-schema"
ok "$(fpresent c1)/$(fpresent c2)" "yes/yes" "T7 ZERO rm — bodies present (actuation runs AFTER validation)"

# T8 PHANTOM DECLARATION → warn+skip, run proceeds (no abort)
build_store; pre="$(mhead)"
d="$(mkdecl '[{"slug":"ghostslug","action":"deleted"}]')"; r="$(ad "$pre" "$d")"; arc=$?
ok "$arc" 0 "T8 phantom (never-existed) declared → ok (warn+skip, no abort)"
ok "$(fpresent c1)/$(fpresent h1)" "yes/yes" "T8 real slugs intact"

exit "$rc"
