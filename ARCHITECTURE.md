# Architecture

High-level design of claude-loop: a self-improving memory + skills loop — markdown, git, and
deterministic shell at the core, LLM calls only where judgment is required, driven by a harness
adapter (Claude Code is adapter #1; see the driver contract below). This file is the stable
reference; day-to-day priorities and open decisions live in `backlog.md` (untracked working notes).

Scope: this file defines **structure** — components, flows, invariants. **Behavior** lives one
layer down, versioned alongside it: judgment in the prompts (`loop/prompts/` — capture bar, tier
assignment, curation rules), quantitative policy in config and gate tables (`config.sh`,
`gates.tsv` — thresholds, caps, cadences; tuned from shadow-log data, not decided in documents).

Components tagged **(planned)** are design-approved but not yet wired; the **Status** section at the
bottom is the authoritative shipped/planned ledger.

**Design axis:** everything important is inspectable, editable, rollback-able, and auditable —
flat markdown files in git, deterministic shell machinery, model calls only where judgment is
required. No databases as stores, no vector indexes, no services.

**Scaling invariant:** *hot grows with what you're doing; cold grows with what you've done.*
The always-in-context layer is bounded by the loader budget and holds only session-invariant
content; accumulated knowledge grows without bound in cold storage at zero context cost, and
returns via retrieval. The unbounded class never consumes the bounded resource.

```
                 WRITE PATH                                 READ PATH
 session transcripts ──► reviewer (LLM) ──┐        ┌─── hot index (auto-loaded, native)
 (Stop / SessionEnd /                     │        ├─── per-prompt injection   (UserPromptSubmit)
  nightly harvest)                        ▼        ├─── subagent-spawn injection (PreToolUse)
                                    gatekeeper     ├─── mid-turn intent gates  (planned, Pre/PostToolUse)
                                 (deterministic)   ├─── session warm-start     (planned, SessionStart)
                                          │        ├─── pull: grep / Read · search CLI (planned)
                                          ▼        └─── peer tools: pointer file (discovery)
                     memory store (markdown + git, typed tiers)
                                     ▲    ▲
   peer agents / human ──► direct file writes — reconciled by INGRESS at every loop entry
                                          ▲
                                 gardener (LLM, nightly + presence self-heal)
                                 skill miner (LLM, scheduled, human-gated)
```

## Homes — what lives where, who may write it

| Home | Contents | Written by |
|---|---|---|
| `LOOP_HOME` (`~/.claude-loop`) | machinery (`bin/ lib.sh hooks/ prompts/ policy/`) · the store (`memory-global/`) · worker-writable state (`proposals/ pending/ state/` — incl. quarantine + materialized profiles — `log/ archive/`) | loop bash; LLM workers only within their platform-scoped profile; peers write the store directly (ingress reconciles) |
| `~/.claude` | `settings.json` (hook registration + `autoMemoryDirectory` → the relocated store) · installed `skills/` (real copies) | operator + deterministic install steps ONLY — the platform protects `~/.claude` from every worker in every non-bypass mode |

**Driver-agnostic core, Claude as adapter #1:** the store, ingress, gatekeeper, validation, and
index/scorer know nothing about which harness drives them. Everything Claude-specific — permission
profiles, spawn flags, the hooks surface, settings repointing — lives behind one `worker_spawn` seam
(lib.sh) plus the install adapter. Adding a driver (e.g. Codex `exec`) means **implementing an
interface**, not editing the three worker flows. The driver contract — what any adapter must provide:

- **Spawn**: `worker_spawn <worker> <model> <effort> <tools-allowlist> <denylist> [extra read-dirs]`,
  prompt on stdin → the driver's JSON result on stdout (the Claude adapter emits `--output-format
  json`, an object-or-array result the workers parse; a new adapter defines its own result shape
  and the seam normalizes), non-zero rc on driver failure.
- **Write scoping (the load-bearing guarantee)**: the spawned worker can write ONLY its per-worker
  scope (reviewer/miner → `proposals/`; gardener → `memory-global/**` + `log/garden-*`, `.git`
  denied) — enforced by the *driver's* mechanism (Claude: materialized permission profiles,
  byte-exact-verified at spawn; another driver: its own sandbox/policy equivalent). The core does
  not re-check writes; this guarantee is what the tripwire and ingress designs assume.
- **Read access**: the driver must ensure the worker can read `LOOP_HOME` (+ any extra dirs
  passed). Any *additional* implicit read surfaces the driver's harness grants must be documented
  and covered by that driver's receipts — read-scope exclusivity is NOT established by the core.
- **Evidence**: the enforcement claim must be receipt-backed by that driver's own live probes
  (in-scope artifact CREATED / out-of-scope ABSENT per worker shape) before it carries the loop —
  the Claude adapter's receipts live in the probe evidence file; a new adapter brings its own.
- **Non-interference**: the driver must not write the operator's protected harness-config surfaces,
  and must not set environment that changes credential resolution for sibling processes (see
  *Operational lessons* in `docs/decisions/de-bypass-relocation.md`).

What stays OUTSIDE the contract (core, driver-blind): ingress, the gatekeeper + exit contract,
`validate_store`, locks, the tripwire zones, quarantine, watermarks, the scorer.
(Decision record: `docs/decisions/de-bypass-relocation.md`.)

## Memory store

One fact per file, YAML frontmatter, in a dedicated git repository. Every memory is typed, and
the type determines where it lives and how it reaches a session. Two vocabularies, deliberately:
the table below is the **conceptual class** (how to think about a memory's lifecycle); the actual
frontmatter enum — what the gatekeeper accepts and the ingress router routes on — is exactly
**`user | feedback | project | reference`** (`feedback`/`user` → hot `MEMORY.md`;
`project`/`reference` → cold `ARCHIVE.md`). Mapping: rule ≈ `feedback`/`user` (hot, graduation
candidates); active state ≈ `project`; reference/archival ≈ `reference` (cold; "archival" is a
lifecycle stage, not a type):

| Conceptual class | What | Home | Reaches a session via |
|---|---|---|---|
| rule | how the agent should behave, applies every turn | instruction layer (CLAUDE.md / output style); memory is only a staging area | always-on instructions, after **graduation** |
| active state (project-class) | in-flight project facts | cold store | retriever; warm-start **(planned)**; expiry via resolution — a `review_after` field is **(planned)** |
| reference | gotchas, APIs, methods (~70% of corpus, ~100% of growth) | **born cold** — never enters the hot index | retriever injection on content-token match |
| archival | resolved investigations, superseded designs | cold | pull only (grep / provenance / backtests) |

- **Hot index** (`MEMORY.md`, auto-loaded natively): session-invariant only — rules awaiting
  graduation, user/environment facts, genuinely cross-cutting reference. Byte-budgeted; the
  budget is a tripwire, not a battleground.
- **Cold index** (`ARCHIVE.md`): everything else. Unbounded, never auto-loaded, fully visible to
  the scorer and grep (and to the search CLI, **planned**).
- **"Hot" is per-session, not global**: each running session assembles its own working set —
  global core + whatever the retriever injects (+ its repo's active-state pointers via the
  warm-start, **planned**). Concurrent
  sessions never see each other's injections (hooks are per-process; telemetry is keyed by
  session).

## Write path

1. **Reviewer** (cheap model; fires from the SessionEnd hook, from the Stop hook's thresholded
   mid-session top-up every ~30 tool calls (`REVIEW_EVERY_TOOLCALLS`, default 30, opt out =0), and
   from the nightly harvest backstop — all gated by `LOOP_ENABLED`, so install never spends;
   rung-2 triage will make the top-up near-free) extracts durable facts from transcripts *into a tier*: reference
   born cold with retrieval-grade (symptom-phrased, aliased) descriptions; rules flagged as
   graduation candidates; knowledge the repo already records is excluded.
2. **Gatekeeper** (`materialize.sh`, deterministic) validates, secret-scans, dedups, detects
   regret (see below), writes the file + index line, and git-snapshots. Only the gatekeeper
   writes real state; the reviewer writes a proposal file behind a write-scope guard.
3. **Gardener** (stronger model, nightly + presence-triggered self-heal) merges near-duplicates
   ("generalize the claim, **keep the tokens**" — description tokens are the retrieval surface),
   re-verifies facts against live code, tightens index lines, curates project-class state (a
   `review_after` expiry field is **planned**), and emits a deterministic `garden-actions.jsonl`
   sidecar of every action.
4. **Graduation**: rules move (never copy) into the instruction layer after a meaning-level diff
   confirms the full bite of the rule is encoded; the memory file is then retired. One home per
   rule — a skill inherits global instructions, so skill + CLAUDE.md double-carry is forbidden.

The gatekeeper returns a four-way **exit contract** — `landed / clean-noop / deferred / failed` —
and the reviewer advances its per-session **watermark** (how far into the transcript has been
reviewed; both the Stop path and the nightly harvest resume from it) only on the first two. A
deferral or failure leaves the watermark alone, so the same slice is retried at the next trigger:
a miss is always a *delay*, never a silent loss.

## External writes — ingress (peers as first-class producers)

The store is not loop-private. Peer agents on the machine — and the human — write memory files
straight into `memory-global/` with no protocol and no locks; that is an expected, first-class
input, not an anomaly. The loop's side of the contract:

- **Reconcile-at-entry:** at every store-mutating entry (review, gatekeeper, gardener), under the
  store lock, the working tree is compared against git HEAD *before the loop does anything*.
  Anything dirty is by definition external. HEAD is never rewritten — it only advances.
- **Deterministic per-slug validation + the type router:** a valid body is source of truth,
  kept byte-identical; its index pointer is *placed* by the declared frontmatter `type`
  (feedback/user → hot, project/reference → cold). The router does **no semantic judgment** —
  missing, non-enum, or conflicting type = broken; a semantically wrong-but-valid type is the
  nightly gardener's problem. Existing pointer prose (operator-curated) is never rewritten:
  correct tier → untouched; wrong tier → the line moves verbatim; only a pointer that exists
  nowhere is generated from the description.
- **Broken files are parked, never lost:** the dirty content is copied to quarantine
  (`state/quarantine/`, outside every validated/guarded dir; `doctor` shows a count) and, if the
  file was tracked, the last good version is restored from HEAD — so one bad file can never wedge
  the store or poison other sessions (the incident class that motivated all of this).
- **Deletions are never honored:** a deleted body or index line is restored from HEAD and the
  attempt recorded. Deletion authority belongs to the gardener alone, via its declared-actions
  contract — so rule-typed memories cannot be removed by anything but human graduation.
- **Green validation → own commit:** the reconciled result lands as its own
  `external-memory-ingress` commit before any loop write — external contributions get durability
  and attribution separate from loop commits, and `validate_store` remains the fail-closed
  predicate on every commit. The invariant survives: **HEAD is always valid.**
- **Windows aren't special:** a valid body that appears in the store *during* a worker's model
  window is the same case — the workers themselves cannot write the store (platform-scoped), so
  any in-window store writer is external, and it is ingested first-class at the next entry rather
  than reverted.
- **Locks are short:** the reviewer holds the store lock only for entry-ingress (+ skips before
  the model spend if the store is busy); the gatekeeper re-ingests and re-validates immediately
  before writing; the gardener holds for its full run; the miner holds while reading its corpus.
  Lock staleness is pid-liveness (`kill -0`), not wall-clock; **no mtime/wall-clock input exists
  anywhere in ingress** — detection is git state and content hashes only.

## Read path

One scorer, many moments. The scorer is a tool-agnostic library (text in → ranked slugs out):
**BM25F over a derived two-field token index** — the index line (title/slug/description) weighted
high, the full memory file (frontmatter + body) weighted low; deterministic, no model
(see `docs/decisions/bm25f-scorer-and-the-ab.md`). Injection always means
the same thing: 1–3 *pointer lines* (slug + description, framed as "possibly relevant — read if
applicable"), never bodies. The model keeps the native recall mechanism — see an index line,
judge relevance, Read the body fresh from disk; the channels only decide *which lines are visible
when*:

1. **Hot index** — auto-loaded, always present, identical in every session.
2. **Per-prompt injection** — score the submitted prompt; the primary channel; follows the
   conversation anywhere.
3. **Subagent-spawn injection** — score the subagent's prompt and append pointers to it
   (subagents otherwise start with no memory context at all).
4. **Mid-turn intent gates (planned — Phase 3; rows exist in `gates.tsv` as shadow, not yet
   registered as hooks)** — the model's intent is legible in tool traffic; gates decide which
   tool events get scored, pre- or post-call. Gates are **data, not code** (`gates.tsv`: name,
   event, tool matcher, field, trigger, threshold, mode) consumed by one generic runner:
   - *friction* (post-call, loose): error-bearing results, repeated failures — score the stderr;
   - *seeking* (pre-call, moderate): search-shaped calls (grep patterns, web queries, doc reads)
     — answer from memory before the expensive lookup;
   - *hazard* (pre-call, tight): tool input touches a known-gotcha surface — warn before the
     mistake.
5. **Warm-start (planned — Phase 3)** (adjunct, explicitly non-load-bearing): at SessionStart, if
   cwd resolves to a known repo, append its few active-state pointers.
6. **Pull**: plain grep/Read (available now), plus a search CLI over the same scorer **(planned —
   Phase 3)**, usable by the agent, by peer tools, and by the human.
7. **Peer tools** — other agent CLIs sharing the machine (anything with a shell): a managed
   pointer block written into their config surface tells them the corpus exists and how to read
   and search it — a *discovery* mechanism, not an injection point. If a peer tool exposes its
   own hook surface, a per-prompt injection adapter *can* be built on the same scorer — written
   only when a real consumer exists, never speculatively.

Shared discipline across channels: per-session slug dedup (reset on compaction), per-channel
thresholds, one measurement kill switch, hooks fail open and fast; a per-turn injection cap is
**(planned — a precondition for the mid-turn gate flips)**.

## Skills track

Separate git-backed store, unchanged by the memory architecture: usage telemetry → autonomous
miner proposes new skills / patches (cross-corpus, scheduled, skip-if-unchanged) → **always
staged, never auto-installed** → human review gate → snapshot-bracketed install. A report-only
curator tracks lifecycle. Two known gaps, both planned: **behavioral (run-and-grade) eval gating**
(current gate is metadata-only), and the **miner's structural blindness** — it mines the distilled
memory corpus plus usage telemetry, *not raw transcripts*, so recurring workflows that never became
memories are invisible to it (repeated procedures rarely clear the memory capture bar). The planned
complement is a raw per-session distiller reading actual transcripts (this harness's and peer
tools'), whose staged output passes the same human gate.

## Verification layer (permanent)

The loop measures itself; every go-live is evidence-gated:

- **Shadow-first** — a one-time deployment gate per channel, *not* a per-session warm-up: every
  NEW injection channel ships log-only, recording what it *would* have injected (including
  misses, with scores — the denominator). When its accumulated log justifies it, the channel is
  flipped live once (a config-row edit); from then on it injects from the first prompt.
- **Read telemetry**: every memory-file Read (main + subagent) logged with session/prompt keys;
  joins against shadow logs give mechanical precision/recall, no human grading.
- **Probes as recall-CI**: a graded probe set runs on every scorer or index-policy change.
- **Regret**: if the gardener *deletes* a memory wrongly, the reviewer organically re-captures it
  and the gatekeeper logs `regret` — an in-the-wild miss detector needing no vigilance. (Today
  this matches exact slugs on deletions only; catching wrong *demotions* and reworded recaptures
  is planned, alongside the cross-source near-match dedup primitive.)
- **Pre-registered A/B**: structural changes (e.g. the hot/cold migration) gate on a mechanical
  offline comparison with commit criteria written before the run.
- **Log-tag contract**: writer/consumer log strings live in one registry (`tags.sh`); a contract
  test fails CI if a tag stops being emitted — instrumentation cannot silently rot.
## Evolution — pre-committed upgrade ladders

The verification layer's telemetry doesn't just monitor — it decides *when the system upgrades
itself*, along ladders agreed in advance so nothing gets relitigated under pressure:

- **Recall ladder** (fires if the vocabulary-mismatch miss class proves common in shadow/regret
  data): write-side aliasing → query expansion → LLM rerank → local embedding hybrid, *last*.
- **Precision levers** (fire on cry-wolf read-rate decay): tighten the threshold a notch, or
  insert a reranker over inject-candidates only (≤ top-3, a few times per session — precision
  without sacrificing recall).

Every rung is evidence-gated, and any test that would close a rung decision goes through the
three-phase adversarial review (design → instrument → inference).

## Safety & control

- Both stores are git repositories; every mutation is snapshot-bracketed; `loopctl rollback` /
  `skill-rollback` revert.
- Kill switches at three levels: loop, measurement, per-gate mode column. `LOOP_ENABLED=0` is
  **fully inert**: every hook AND every scheduled/detached entry point (gardener/harvest/miner)
  exits early — no writes, no spend, no scheduled run — and `doctor` treats "schedule absent while
  disabled" as coherent, not a warning.
- `LOOP_REVIEWER=1` is the opt-out contract: every loop-internal or loop-adjacent worker/model
  call (reviewer, gardener, miner, probes, backtests) exports it so hooks and telemetry ignore
  those sessions.
- **Platform-enforced least privilege (#23):** the LLM workers (reviewer, gardener, miner) consume
  UNTRUSTED input — transcript slices, memory bodies — so each runs under the driver adapter's
  least-privilege enforcement, writes path-scoped to its per-worker scope: reviewer/miner may write
  only `proposals/`, the gardener only the store + its garden log outputs (store repo-metadata
  denied). The enforcement mechanism belongs to the *driver* (see the driver contract above); the
  relocation to `LOOP_HOME` is what makes fine-grained scoping expressible at all. A prompt-injection
  that tries to write outside a worker's scope is denied by the platform, not merely by a denylist.
  A tool denylist is kept as a second, independent layer, contract-tested at the spawn seam; `doctor`
  flags a stale/missing profile, and a worker hard-fails rather than spawn without an intact one.
  Adapter-specific mechanics — rule syntax, profile materialization, and the empirically established
  traps — live in `docs/decisions/de-bypass-relocation.md`.
- **The tripwire (#23, replaces the mirror/guard):** platform permissions govern the MODEL's tool
  calls only — a hook/MCP/subprocess side-effect is plain bash and can write anywhere. So each worker
  fingerprints the *impossible zones* (pending/, installed skills/, and the `.git` of memory-global +
  skills) before and after its model window; any change is an ungoverned side-effect → **evidence-only
  ABORT**, no restore (the store's validity is enforced separately by `validate_store`). The `.git`
  fingerprint is checked GIT-FREE and, on the gardener's failure path, aborts BEFORE any git op — else
  a tampered `.git/config` helper (core.fsmonitor/filter.clean) would run on the very restore meant to
  recover. A memory-global BODY write is NOT a zone hit: that is ordinary external traffic, reconciled
  by the ingress path (valid → accepted first-class, invalid → parked).
  - **Invariant — installed guarded artifacts are copies, not symlinks:** the zone fingerprint walks *real*
    files (`find`, no `-L`), so a symlinked skill dir's target edit would be invisible to the tripwire. Install
    therefore keeps skills as copies even in `--link` mode (the `--link` machinery symlinks live outside
    `SKILLS_DIR`), and `doctor` flags any symlink under installed skills. (This is a policy invariant, not a
    `find`-flag choice: following symlinks would instead pull unbounded external trees into the fingerprint.)
- **Profiles are integrity-checked, not just fresh (#23):** a materialized worker profile is a load-bearing
  *mutable* control file, so both `doctor` and the worker spawn compare it **byte-for-byte** against a fresh
  render of its template — an added/edited allow-rule fails the check even if the realpath prefix still matches,
  and the worker refuses to spawn (fail-closed). All three workers spawn through one `worker_spawn` seam that
  owns the profile check + the driver flags, so a different driver swaps one function, not three scripts.
- Skills never auto-install; instruction-layer edits (graduation) are human-gated; memory
  auto-write is mode-gated (`dry-run` stages everything).
- `loopctl status | stats | doctor` is the operator surface; scheduled runs self-heal on
  presence (Stop/SessionStart hooks) rather than relying on the machine being awake at 3am.

## Status

- **Shipped (implemented and live today):** write path (reviewer → gatekeeper → store), gardener
  + telemetry, skills track, measurement substrate (shadow logging, read telemetry, probes-CI,
  regret, tags contract, CI), peer-tool pointer surface.
- **Landed and verified live, currently gated off (operator cost decision):** hot/cold store split,
  the injection engine (gate-runner; prompt-submit + subagent-spawn rows), capture-into-tier +
  POLICY interpolation — all installed and exercised live (injection verified end-to-end). The
  scheduled automation is disabled by the operator on cost grounds; the injection (read) path is
  independent of that switch. Re-enable is now gated on the readiness steps below, not on missing
  hardening.
- **Hardening — SHIPPED + accepted (these were the re-enable blockers):** loop kill switch gates
  every scheduled/detached entry point, not just the hooks (`accdf98`); gardener store-integrity
  validate-then-commit + auto-restore — a failed or malformed run restores the pre-run snapshot and
  never commits a partial mutation as HEAD (`ba30d1f`); declared-actions intent contract — the
  gardener declares its drops, validation fails closed on any undeclared/rule-typed drop (`b4892d7`);
  xhigh hardening pass — traversal-safe index targets, fully-inert kill switch across all hooks,
  declared-actions schema enforcement (`6286d23`).
- **Safety invariant — platform-enforced least privilege + tripwire (#23):** every LLM worker
  (reviewer/gardener/miner) runs in DEFAULT mode (bypass dropped) against a materialized per-worker
  permission profile that path-scopes its writes — enforced by the platform (Claude adapter) because the store moved to
  `LOOP_HOME` out of the protected `~/.claude`. The `--disallowedTools` denylist (incl. Bash) is kept as
  a second layer. A per-window tripwire fingerprints the impossible zones (pending/, skills/, and the
  `.git` of memory-global + skills) and aborts on any ungoverned side-effect, `.git` checked git-free
  before any git op. Contract-tested; profile freshness surfaced by `doctor`. (Supersedes the earlier
  `bypassPermissions` + denylist-only model, `9bd7b9e`.)
- **Reviewer — slice-only (`5e8dd91`):** the reviewer judges its transcript slice + the POLICY
  capture bar/exemplars and does NOT browse the memory store. A blind A/B (26 slices) found
  store-browsing *suppressed* capture; dedup correctness rests downstream on the gatekeeper's
  exact-reject + the nightly gardener's near-dup merge.
- **Pending a human sitting:** the rules graduation batch (memory → instruction layer).
- **Re-enable readiness (the gate now):** **migrate first** — `./claude-loop migrate` relocates the
  live `~/.claude/loop` + `~/.claude/memory-global` to `LOOP_HOME` (`~/.claude-loop`), resumably, keeping
  git history and repointing settings hooks + `autoMemoryDirectory`; it refuses while the loop is enabled
  and validates the store before moving. Then re-flip `gates.tsv` rows 1–2 → `live` (plain-copy install
  resets them to shadow); and bring the slice-only reviewer live only with the gardener running nightly +
  a dup-rate monitor armed (dedup moved downstream when the reviewer stopped browsing).
- **Planned (Phase 3):** mid-turn gates (shadow-first, friction first), warm-start, search CLI,
  per-turn injection cap; then the backlog's NEXT track (incl. skill-pointer injection).
