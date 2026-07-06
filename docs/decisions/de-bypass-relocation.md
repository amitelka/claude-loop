# Decision: drop `bypassPermissions`; relocate the store to `LOOP_HOME`; guard the rest with a tripwire

**Status:** implemented + tested, ship-gated on final review (2026-07-06) · **Scope:** how the `claude -p` workers
(reviewer, gardener, miner) are constrained, and where the loop's machinery + store live.

## Context
The workers run `claude -p` on **untrusted input** — transcript slices and memory bodies a prompt-injection can
ride. The prior model ran them under `--permission-mode bypassPermissions` and relied on two things: an explicit
`--disallowedTools` denylist (Bash + exec/exfil/spawn), and a per-window **mirror/guard** that snapshotted the
non-store trees, diffed after the model run, and *restored* any out-of-scope write. Two problems: (1)
`bypassPermissions` turns off the platform's own write enforcement — the denylist is the only lever, and it must
be chased every time Claude Code adds a tool; (2) the store lived at `~/.claude/memory-global` and the machinery at
`~/.claude/loop`, both **inside** `~/.claude` — a Claude-Code-**protected** path where fine-grained per-worker
write scoping can't be expressed, which is *why* bypass was reached for in the first place.

## Decision
Three coupled moves:
1. **Relocate** machinery + store to `LOOP_HOME` (`~/.claude-loop`), out of the protected `~/.claude`. `~/.claude`
   keeps only hooks, `settings.json`, and the skills-discovery dir. `settings.autoMemoryDirectory` is repointed so
   native auto-memory reads the relocated store (the loop owns that setting — else it would curate one dir while
   Claude auto-loaded another).
2. **De-bypass** the workers: run in **DEFAULT** permission mode against a materialized per-worker permission
   profile (`--settings <profile>`) that path-scopes writes — reviewer/miner → `proposals/` only; gardener →
   `memory-global/**` + `log/garden-*`, with `memory-global/.git/**` denied. The platform now *enforces* the
   boundary. The denylist stays as a second layer.
3. Replace the mirror/guard with an **evidence-only tripwire**: fingerprint the *impossible zones* (pending/,
   installed skills/, and the `.git` of memory-global + skills) around each model window; any change is an
   ungoverned side-effect → **abort, no restore** (store validity is enforced independently by `validate_store`).

## Evidence
- **The mechanism was established empirically, not assumed.** A permission-probe sequence pinned the exact recipe:
  path-scoped Write requires `settings.json` `permissions.allow` in **default** mode (a bypass run *ignores*
  `--allowedTools`, and `--allowedTools` alone does not grant path-scoped Write); rules must use the `//`-**realpath**
  absolute form (a single leading `/` is settings-relative, and the macOS `/tmp`→`/private/tmp` symlink otherwise
  makes an in-scope path silently DENY); and a Write *creation* needs BOTH `Write` and `Edit` allow rules. The
  profiles bake `realpath(LOOP_HOME)` into the `@@LH@@` template at install/`reprofile` for exactly this reason.
- **Relocation is the enabler:** with the store out of `~/.claude`, `tests/relocation_test.sh` asserts machinery +
  store land at `LOOP_HOME`, `settings.autoMemoryDirectory` + hooks repoint there, and skills stay at
  `~/.claude/skills` — no machinery is created at the old `~/.claude/loop` path.
- **Profiles + least privilege:** `tests/profiles_test.sh` asserts all three profiles materialize with no
  unsubstituted placeholder, the `//`-realpath rule form, correct per-worker scope (reviewer/miner proposals-only;
  gardener memory-global with `.git` denied), and the `doctor` freshness verdict (fresh → STALE when a profile is
  missing → restored by `reprofile`).
- **Tripwire, incl. the ordering that matters:** `tests/tripwire_test.sh` asserts a pending/skills write in a
  worker window aborts (no advance / nothing staged); a memory-global **body** write is *not* a zone hit (it is
  reconciled as ordinary external traffic); and — the load-bearing case — a `.git/config` `core.fsmonitor` helper
  planted mid-gardener-window **never fires**, because the `.git` fingerprint is checked git-free and aborts
  BEFORE the failure path's own git op would execute it. A control in the same test proves the helper *does* run on
  a git op in that environment, so the "never fires" assertion is not vacuous.
- **Migration is safe + resumable:** `tests/migrate_test.sh` asserts `migrate` refuses while enabled, **validates
  the store before moving** (a failure leaves it canonical at the old path, nothing repointed), `mv` keeps git
  history, carries state/config/.env/pending, repoints settings, writes an **exec-only** compat shim at the old
  path, is idempotent, and resumes from the failed phase after the store is fixed.

## Consequences & triggers
- **Posture shift (ratify):** deleting the window guard means a *valid* memory body written into the store during a
  worker window is no longer reverted — it is reconciled and accepted as first-class (the #16 external-producer
  model), while the store stays `validate_store`-valid. This is coherent because a real worker **cannot** write the
  store (platform-scoped), so the only in-window store writer is an external process, which #16 already treats as
  first-class; the guard was redundant belt-and-suspenders, not the load-bearing control. The load-bearing controls
  are now: platform scope (worker can't stray), the tripwire (impossible zones + `.git`), and `validate_store` (the
  store never commits invalid).
- **Denylist still chased:** the `--disallowedTools` second layer must still be revisited as Claude Code adds
  tools; the contract test over `bin/` call-sites remains.
- **Doctor is the health surface:** a worker hard-fails without a matching-path profile, so `doctor` reports
  profile freshness and `reprofile` re-bakes after any `LOOP_HOME` move.
- **`.git` in the fingerprint is a cost/coverage tradeoff:** hashing the guarded `.git` dirs each window is cheap at
  memory-store scale but grows with history; if it ever bites, narrow to the RCE-relevant paths (`config`,
  `hooks/`, `info/`) rather than the whole `.git`.

## Operational lessons (referenced from ARCHITECTURE)

Established empirically during the probe campaign and the build; recorded here so design documents
can stay driver-neutral and cite this record instead of retelling war stories:

- **Credential-resolution env is process-global state:** exporting the harness's config-home
  variable (`CLAUDE_CONFIG_DIR`, for the Claude adapter) flips the CLI from keychain credential
  resolution to file-based credentials — absent on a keychain-auth machine, every spawned call
  fails "not logged in". The loop therefore reads such variables for *path* resolution only and
  never exports them around worker spawns; the driver contract's non-interference clause
  generalizes this to any adapter.
- **Rule-path canonicalization:** permission-rule paths must be realpath-resolved before baking
  (`/tmp` → `/private/tmp` on macOS); a non-canonical in-scope rule fails CLOSED — silently denying
  legitimate writes rather than allowing illegitimate ones.
- **Grant-shape completeness:** a file *creation* under the Claude adapter requires BOTH `Write`
  and `Edit` allow rules on the scope; a Write-only profile silently denies creation. Probe
  controls distinguish "mechanism broken" from "rule shape incomplete".
- **Verification context matters:** headless probe results are only valid from an execution
  context that authenticates the way the deployed workers do; three probe runs were invalidated
  by context/auth confounds before the first valid result. Probe evidence must record its context.
