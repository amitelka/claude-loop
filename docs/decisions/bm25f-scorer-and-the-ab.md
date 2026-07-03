# Decision: BM25F as the retriever scorer, chosen by a pre-registered A/B

**Status:** accepted (2026-07-03) · **Scope:** the one scorer behind the hook, the recall-probe, and probes-CI.

## Context
Splitting memory into a small auto-loaded hot tier and a retriever-only cold tier
([hot-cold-tiering](hot-cold-tiering.md)) only pays off if the retriever actually recovers a cold memory when a
real prompt needs it. So the scorer had to be *measured*, not asserted — and measured against the thing it
replaces (an always-loaded index line that survives only until it's pushed past the loader's byte budget).

## Decision
Ship **`bm25f-1`**: BM25F over a derived per-field token index, **description field ×3, full-file field ×1**
(k1=1.2, b=0.75; IDF computed over field-union document frequency). The low-weight field tokenizes the whole
memory file — YAML **frontmatter + body** — not the prose alone: universal metadata keys (`name`, `description`,
`metadata`, `type`, …) appear in every file so their IDF is ~0 (nullified), while the per-memory `repo:` tag
enters the index as signal. Weights are a-priori, **not** tuned on the probe set. The scorer reads *both* fields
but the loop injects **only the pointer**; the full file is scored for recall, never shipped. The live index is a flat per-field token file rebuilt on write (gitignored) — **no FTS5**
at a ~10² corpus. Description enrichment was tried and **rejected as measured-dead**
([enrichment-rejected](enrichment-rejected.md)).

## Evidence
Four scorers, one hermetic harness, corpus pinned at memory rev `d7783f1`, metric = expected memory in top-3,
±1 hit = noise floor. Probe set: **28 positives** spanning hot-resident / active / cold tiers, **15 negatives**
(prompts with no relevant memory). Residency (is it in the hot tier) and scorer-hit (does the scorer rank it)
are reported separately so a hot memory scoring poorly can't hide behind its residency.

| scorer | sha | recall@3 | ACTIVE | COLD |
|---|---|---|---|---|
| count-desc (raw token overlap, desc only) | `cdbea08646e5` | 21/28 | 4/6 | 15/18 |
| bm25-desc (BM25, desc only) | `49bb19276ee1` | 22/28 | 5/6 | 15/18 |
| bm25-bodyonly | `0bf05f37de20` | 22/28 | 5/6 | 15/18 |
| **bm25f-1 (shipped)** | `0bf05f37de20` | **24/28** | **6/6** | **16/18** |

- **count → bm25-desc = Δ1 = parity.** The BM25 swap ships on theory and robustness (raw overlap counts a rare
  distinctive token the same as a common one), **not** on a measured recall gain.
- **bm25-desc → bm25f = Δ2, a strict +2/−0 improvement, and no gained hit is cutoff-fragile.** The one top-3
  tie in the run is on a *negative* probe (`n14`, no expected memory), so no counted hit rode in on a coin-flip.
  The gain is real and comes from *scoring the body*, not from tuning.

**Why the test is trustworthy:**
- **Pre-registered** commit criteria (cold recall ≥ status-quo; hot no-regression; the zero-overlap "conceptual"
  miss class quantified) with an honest amendment log for every deviation.
- **Hermetic + pinned:** every cell runs against a git-archived copy of the corpus at one rev, recording the
  scorer's own SHA — no live paths, fully reproducible.
- **Blind labeling + independent reproduction:** expected memories were labeled from prompt+body blind to the
  scorer; a second agent re-ran all cells (matching SHAs) and blind-relabeled (38/43 exact, 41/43
  overlap-or-both-none, **no bad positive labels**).
- **The control arm is a finite prefix, not a scalable baseline.** The status-quo "18/18 in-window" is coverage
  measured only over the first ~24.4 KB of `MEMORY.md`, which at this rev already measured **25,017 B**
  (`git show d7783f1:MEMORY.md | wc -c`) — over budget. So the 18 is recall of a **bounded prefix**: memories
  past the cutoff are already invisible, and the prefix cannot cover unbounded future captures. The retriever, by
  contrast, scores the **whole corpus** (no byte-position cutoff), with recall guarded by probes-CI and the
  operating-point drift alarm — it is *not* corpus-size-independent (BM25 scores shift as the corpus grows; see
  [threshold-operating-point.md](threshold-operating-point.md)), which is exactly why that monitoring exists. The
  honest comparison is *16 measured over the full corpus under monitoring* vs *18 from a finite, already-over-budget
  prefix that can't scale* — not 16 vs 18 head-to-head.

**Verification note (2026-07-03).** Every figure above was re-derived from the per-cell artifacts
(`.backups/migration-harness/artifacts/*.json`), not from working notes — a build-time chat table mis-transcribed
`bm25-bodyonly` as 21/28 (COLD 14/18); the artifact value **22/28 (COLD 15/18)** is authoritative and is what's
tabled here.

## Consequences & triggers
- **Residual = 2 misses, both genuinely conceptual** (prompt and memory share no meaningful tokens — the exact
  case lexical scoring cannot solve). That, not a scorer tweak, is what the escalation ladder exists for
  ([reranker-vs-embeddings-roles](reranker-vs-embeddings-roles.md)); it stays gated until the conceptual-miss
  class is shown *persistent* in shadow, ~2/18 today.
- **The A/B-tested artifact is the shipped artifact** — the same scorer file feeds hook, recall-probe, and
  probes-CI, so a regression in any path is a regression in all.
- **probes-CI is permanent, not one-shot:** it re-runs the harness on every scorer/index-policy change and
  fails on a recall drop below the shipped baseline.
- **Frontmatter-strip: measured at parity-within-noise → bm25f-1 stands.** A pre-specified variant — identical to
  `bm25f-1` but stripping the leading YAML frontmatter from the low-weight field — ran as one hermetic cell at
  `d7783f1` (`.backups/migration-harness/artifacts/bm25f-fmstrip-1.json`; builder + runner preserved beside it):
  **23/28** vs 24/28 = **Δ−1, which is ≤ the declared ±1 noise floor → PARITY**, not a measured difference. No
  evidence stripping helps, and a swap would cost a probes-CI re-baseline for nothing, so **bm25f-1 stands**
  (incumbent by parsimony — *not* because full-file is "better"). *Anecdote, not a conclusion (one probe, within
  noise — consistent-with, not confirmed-by):* the lone changed hit (p19, cold) coincides with frontmatter carrying
  its `repo:`/description-echo tokens. **Instrument fidelity confirmed** by an independent token-set diff (index
  materially differs, desc field byte-identical, true body tokens survive incl. body-`---`/CRLF/no-frontmatter
  edges; cell re-run reproduced 23/28) — so the −1 is real, not an over-strip artifact. *Revival caveat:* the
  variant's stripper is `split("---")`-based, not line-anchored — a literal `---` inside a frontmatter value would
  misstrip; harmless for the generated format, but use an anchored regex if it is ever shipped.
