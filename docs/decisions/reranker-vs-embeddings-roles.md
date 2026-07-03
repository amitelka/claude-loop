# Decision: an evidence-gated escalation ladder — rerank for precision, embeddings for recall, last

**Status:** accepted as a pre-committed plan, not yet built (2026-07-03) · **Scope:** how retrieval escalates
beyond lexical scoring, and in what order.

## Context
The shipped BM25F scorer leaves **2 residual misses** (probes `p23`, `p26` in
`.backups/migration-harness/artifacts/bm25f-1.json`, both `erank=null` in the cold bucket): cases where the
prompt and the memory share essentially no tokens — the conceptual / vocabulary-mismatch class that lexical
scoring structurally cannot solve. "Add embeddings" is the reflexive answer, but it's the wrong *first* move and
conflates two different failure modes (missing a hit vs injecting a bad one).

## Decision
A single ordered ladder, each rung **evidence-gated**, embeddings **last**:
1. **Write-side symptom-phrasing / aliasing** (already core, in [POLICY.md](../../POLICY.md)).
2. **BM25F term weighting** — shipped ([bm25f-scorer-and-the-ab.md](bm25f-scorer-and-the-ab.md)).
3. **Query-side expansion.**
4. **Rerank — the PRECISION rung.** A cross-encoder / LLM judging the top candidates jointly with the query
   (~1 s), run **only on inject-candidates (≤ top-3, a few times per session), never per-prompt** — which dodges
   the latency/cost/determinism objections to an LLM in the hook. It catches mismatch evidence — platform,
   negation, version qualifiers — that *both* lexical overlap and cosine similarity structurally ignore.
5. **Embeddings — the RECALL rung, last.** For the true vocab-mismatch residue only; indexes **bodies** (a
   compressed description loses the semantics). Deployed as hybrid: lexical ∪ embedding candidates, fused then
   reranked.

## Why rerank ≠ embeddings (the crux)
They solve opposite problems. **Embeddings widen the candidate net** (recall) — but lookalikes are *topically
close*, so cosine fires on them too; embeddings are **not** a precision tool. **Rerank narrows** with
joint query+candidate attention (precision) — it reads the qualifiers cosine averages away. Reaching for
embeddings to fix a precision complaint makes it worse.

## Triggers (the metric decides WHEN; the ruling picks WHICH)
- **Recall rungs (query-expansion → embeddings)** fire only when the conceptual-miss class is shown **persistent**
  in shadow logs. Today it's ~2/18 — real but rare — so **not yet**.
- **Precision rung (rerank)** fires on **cry-wolf read-rate decay** (injected pointers being ignored). That same
  signal has a cheaper alternative response — tighten the threshold
  ([threshold-operating-point.md](threshold-operating-point.md)) — trading recall for precision; the read-rate
  says when to act, the ruling that day picks which lever.
- Field rulings for if/when built: BM25 rung = a weighted-column index (description high, body low); embedding
  rung = body/chunks. Storage stays lexical-first — the binding constraint is context budget, not storage tech,
  so **no vector DB / no SQLite-as-store** is implied by any of this.
