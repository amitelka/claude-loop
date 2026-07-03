# Decision: split memory into an auto-loaded hot tier and a retriever-only cold tier

**Status:** accepted (2026-07-03) · **Scope:** memory-global layout + what auto-loads each session.

## Context
The always-in-context layer (`MEMORY.md`, auto-loaded every session) is one **bounded** resource — the loader
truncates it at a byte budget. Accumulated knowledge is **unbounded** — an always-on reviewer adds to it
continuously. A flat always-on index feeding from an unbounded producer is structurally mismatched: it doesn't
*whether* it overflows the budget, only *which week*. And overflow is silent — truncation is uncontrolled
demotion by byte-position, cutting whatever sorts last. At the pinned rev the index already measured
**25,017 B** (`git show d7783f1:MEMORY.md | wc -c`) against a ~24.4 KB auto-load budget: already over.

## Decision
Two tiers. **Hot** (`MEMORY.md`, auto-loaded): the session-**invariant** only — working-style rules, who the
user is and their environment, cross-cutting facts. **Cold** (`ARCHIVE.md`, not auto-loaded, reached by the
retriever or grep): everything scoped to one tool/repo/task/incident. The governing invariant: **hot grows with
what you're _doing_; cold grows with what you've _done_.** New captures are routed to a tier deterministically by
**type** (feedback/user → hot; reference/project → cold — see [POLICY.md](../../POLICY.md)); the gardener
promotes the rare cross-cutting reference that belongs hot. Deliberate, criterion-based demotion replaces silent
byte-position truncation.

## Evidence
- The one-time migration split **151 memories → 43 hot / 108 cold** (`.backups/migration-harness/hot-slugs.txt`,
  `cold-slugs.txt`) — deterministic, by frontmatter type.
- Demoting a memory to cold only pays off if the retriever can recover it on demand. That is exactly what the
  scorer A/B measured before this landed: cold recall@3 **16/18** over the *full* corpus (no byte-position cutoff,
  recall monitored by probes-CI), versus the always-on baseline's **18/18** measured only over a finite prefix
  already over budget that cannot cover future captures. Full method, numbers, and why the test is sound:
  [bm25f-scorer-and-the-ab.md](bm25f-scorer-and-the-ab.md).

## Consequences & triggers
- Cold memories give up their always-on line and **depend on retrieval** — so this decision is only safe *because*
  the retriever ships with it (they land together; a migrated store with retrieval off would strand cold memories).
- The ~2/18 the retriever can't recover today are conceptual (vocab-mismatch) misses; they gate the escalation
  ladder ([reranker-vs-embeddings-roles.md](reranker-vs-embeddings-roles.md)), not a re-merge into hot.
- Type→tier is a deterministic proxy for the real hot criterion (token-poor AND broadly-applicable); borderline
  items (e.g. a broadly-useful reference landing hot) are reconciled by the gardener and the graduation review.
