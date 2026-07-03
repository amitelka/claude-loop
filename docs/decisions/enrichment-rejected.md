# Decision: description-enrichment rejected as the recall lever (a negative result)

**Status:** accepted / negative result (2026-07-03) · **Scope:** whether to rewrite memory descriptions with
symptom/alias tokens to improve retrieval. Kept as a record because negative results are load-bearing too.

## Context
When the cold-recall A/B first looked marginal, the pre-committed first fallback was **description-enrichment** —
rewrite cold descriptions with symptom phrasing and vocabulary aliases so a prompt's words overlap the memory's.
The plausible theory: more matching tokens → more hits.

## Decision
**Enrichment is not the lever; shelved (kept, not deleted).** The recall gain came from changing the **scorer**
(field-weighted BM25F that scores the body), not from enriching content. Enrichment stays on the shelf — it may
help under a future instrument — but it is not what ships and not what the recall story rests on.

## Evidence
Two parts, and the honest distinction between them matters:

- **Receipt-backed (the reliable finding):** with descriptions left as-is, moving the scorer from raw token-count
  to BM25F took recall@3 from **21/28 → 24/28** (`.backups/migration-harness/artifacts/count-desc.json` vs
  `bm25f-1.json`; full table in [bm25f-scorer-and-the-ab.md](bm25f-scorer-and-the-ab.md)). The lift is the
  **scorer**, applied to unchanged content.
- **The unreliable data (the record's subject):** the enrichment arm's own numbers are **not trustworthy** and
  are not cited as fact here. The cheap first pass ran under a **broken instrument** — the raw-count scorer, where
  extra description tokens *crowd* rather than help — and a **provenance error**: a scoring script was repurposed
  onto the enriched corpus, producing an early "5/6→3/6" figure that did **not reproduce** under the hermetic
  runner. No clean enrichment cell artifact survives, by design: it was the flawed run that motivated fixing the
  instrument, not a result to quote.

## Consequences & triggers
- **Principle — instrument-before-treatment:** order experiment levers by *validity*, not build cost. Fix and
  verify the measuring instrument (scorer, metric, control arm) **before** tuning the content it measures. A cheap
  lever run under a broken instrument produced a false "enrichment is net-negative, period" verdict; only a clean
  scorer arm settled it.
- Enrichment is not foreclosed forever — if the escalation ladder reaches a rung where description quality gates
  recall, it can be re-measured **under a validated instrument**. Until then it stays shelved.
