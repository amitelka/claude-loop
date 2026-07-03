# Decision: inject pointers, not memory bodies

**Status:** accepted (2026-07-03) · **Scope:** what the retrieval hooks put into context on a match.

## Context
Cold memories don't auto-load, so something has to surface them when a prompt needs one. The naive move is to
inject the matched memory's full text. That has two costs: it spends context on a body that may not be relevant
(the scorer decides *candidacy*, not *applicability* — the model is the better judge of the latter), and it feeds
a **snapshot** that can already be stale relative to the file on disk.

## Decision
Inject the **pointer** — the memory's one-line index entry, under a hint frame
(*"possibly relevant memories — read the file if it applies, ignore if not"*) — never the body. The model Reads
the actual file only if the pointer looks relevant, so it reads the **current source** at the moment of use. A
per-session dedup suppresses re-injecting a pointer already surfaced; that dedup **resets on `PreCompact`** so a
long session doesn't permanently lose a pointer a compaction dropped from context.

## Evidence
- Behavior is pinned by a hermetic smoke test (`loop/tests/injector_smoke_test.sh`): a live gate emits the
  hint-framed pointer line for a matching prompt, re-injection of the same slug in-session is suppressed, a shadow
  gate logs but never injects, and the kill switch yields nothing — all asserted green.
- Framing and pointer-only emission are in the single injection engine (`loop/bin/gate-runner.sh`): it greps the
  index line for each surviving candidate and emits that, not the file contents.
- Cost framing is concrete: the prior design auto-loaded the entire index — **151 pointer lines** at the pinned
  rev (`git show d7783f1:MEMORY.md | grep -cE '^- \['`) — every session; a false-injected *pointer* is ≈ one
  ignored line, and dedup collapses repetition, so recall-favoring injection is cheap.

## Consequences & triggers
- Because pointers are cheap, the operating point is deliberately recall-favoring
  ([threshold-operating-point.md](threshold-operating-point.md)); the guard against pointer spam is not a tight
  threshold but a **monitored read-rate**.
- **Cry-wolf metric:** the injected-pointer Read-rate (shadow⋈read telemetry) measures the channel's credibility.
  Sustained decay means pointers are being ignored → fire a precision lever
  ([reranker-vs-embeddings-roles.md](reranker-vs-embeddings-roles.md)).
- Subagents can't receive a parent-side pointer, so their case needed a different delivery mechanism, verified
  separately: [subagent-inject-mechanism.md](subagent-inject-mechanism.md).
