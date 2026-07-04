# Architecture

High-level design of claude-loop: a self-improving memory + skills loop built natively on Claude
Code (hooks, `claude -p`, markdown, git). This file is the stable reference; day-to-day priorities
and open decisions live in `backlog.md` (untracked working notes).

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
                                          ▲
                                 gardener (LLM, nightly + presence self-heal)
                                 skill miner (LLM, scheduled, human-gated)
```

## Memory store

One fact per file, YAML frontmatter, in a dedicated git repository. Every memory is typed, and
the type determines where it lives and how it reaches a session:

| Type | What | Home | Reaches a session via |
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

1. **Reviewer** (cheap model; fires per ~N tool calls via the Stop hook, on SessionEnd, and from
   a nightly harvest backstop) extracts durable facts from transcripts *into a tier*: reference
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
- `LOOP_REVIEWER=1` is the opt-out contract: every loop-internal or loop-adjacent `claude -p`
  (reviewer, gardener, miner, probes, backtests) exports it so hooks and telemetry ignore those
  sessions.
- **Untrusted-input tool denylist:** the LLM workers (reviewer, gardener, miner) run `claude -p`
  on UNTRUSTED input — transcript slices, memory bodies — under `--permission-mode
  bypassPermissions`, which *ignores* `--allowedTools`. Each therefore carries an explicit
  `--disallowedTools` denying Bash and the exec/exfil/spawn tools it never needs, so a
  prompt-injection cannot steer a worker into a shell command. A denylist is the only lever the CLI
  exposes headless (unlike a runtime-dispatch whitelist, which needs owning the loop) — so it must
  be revisited when Claude Code adds tools; a contract test asserts every `claude -p` in `bin/`
  carries it.
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
  every scheduled/detached entry point, not just the hooks (`b035e36`); gardener store-integrity
  validate-then-commit + auto-restore — a failed or malformed run restores the pre-run snapshot and
  never commits a partial mutation as HEAD (`d4dc8fd`); declared-actions intent contract — the
  gardener declares its drops, validation fails closed on any undeclared/rule-typed drop (`8b261fd`);
  xhigh hardening pass — traversal-safe index targets, fully-inert kill switch across all hooks,
  declared-actions schema enforcement (`85f0c7f`).
- **Safety invariant — untrusted-input denylist (`baefe25`):** every `claude -p` worker
  (reviewer/gardener/miner) runs `--permission-mode bypassPermissions` on UNTRUSTED input (transcript
  slices, memory bodies), which ignores `--allowedTools`; each therefore carries `--disallowedTools`
  including Bash (the only headless gate against a prompt-injection steering a worker into a shell).
  Contract-tested against new call-sites.
- **Reviewer — slice-only (`0258f9f`):** the reviewer judges its transcript slice + the POLICY
  capture bar/exemplars and does NOT browse the memory store. A blind A/B (26 slices) found
  store-browsing *suppressed* capture; dedup correctness rests downstream on the gatekeeper's
  exact-reject + the nightly gardener's near-dup merge.
- **Pending a human sitting:** the rules graduation batch (memory → instruction layer).
- **Re-enable readiness (the gate now):** reinstall from the repo FIRST (the live `~/.claude/loop`
  is a copy install — hardening commits are repo-only until reinstalled); re-flip `gates.tsv` rows
  1–2 → `live` after install (plain-copy install resets them to shadow); and bring the slice-only
  reviewer live only with the gardener running nightly + a dup-rate monitor armed (dedup moved
  downstream when the reviewer stopped browsing).
- **Planned (Phase 3):** mid-turn gates (shadow-first, friction first), warm-start, search CLI,
  per-turn injection cap; then the backlog's NEXT track (incl. skill-pointer injection).
