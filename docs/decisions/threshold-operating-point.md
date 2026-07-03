# Decision: inject-threshold at the sweep's max-recall point (5.1), monitored for drift

**Status:** accepted (2026-07-03) · **Scope:** the score threshold gating the inject stage (gates.tsv rows 1–2).

## Context
The scorer ranks candidates; a threshold decides which are worth injecting. A precision sweep over 15 negative
probes (prompts with no relevant memory) showed **no threshold cleanly separates** plausible look-alikes from
true hits — their top scores share a range. So the choice isn't "find the clean cut" (there isn't one); it's
"pick an operating point on the recall/false-inject curve," under the ruling that false-injects are cheap
(a pointer ≈ one ignored line — [pointer-injection-not-bodies.md](pointer-injection-not-bodies.md)).

## Decision
Set the threshold to **5.1**, the **max-recall operating point** of the sweep: it keeps *every* achievable hit
while shedding the weakest false-injects. It **strictly dominates 0** — same recall, fewer false-injects — so it
is a free precision gain over "inject on any nonzero score," not a recall sacrifice. Both live gates ship at 5.1.

## Evidence
From the shipped scorer's precision sweep (`.backups/migration-harness/artifacts/bm25f-1.json`, `.precision.sweep`):

| threshold T | recall (of 24 achievable) | false-injects (of 15) |
|---|---|---|
| 1.46 (lowest observed; any nonzero match) | 24 | 15 |
| 4.3 | 24 | 14 |
| **5.1 (chosen)** | **24** | **12** |
| 5.41 | 23 | 12 |

5.1 is the **largest** T that still retains full recall (24) — one step up, at 5.41, recall drops to 23. So 5.1
is the precise knee: maximum false-inject shedding at zero recall cost.

## Consequences & triggers
- **5.1 is a snapshot calibration.** BM25 scores are non-stationary — IDF, N, and average field lengths all shift
  as the corpus grows — so a fixed constant will drift out of true. `loop/tests/probes_ci_test.sh` recomputes the
  sweep's max-recall operating point each run and **WARNs (non-failing)** when it diverges from the configured
  threshold by more than 1.0, printing both values. Threshold tuning becomes a monitored alarm, not a guess.
- **Succession plan, triggered by that alarm:** replace the constant with a **quantile rule** — T = the pXX of the
  negative-set top-1 scores, recomputed per rev by probes-CI — so the operating point self-calibrates against the
  actual score distribution. Not built now; the alarm is the trigger.
- The same cry-wolf read-rate that governs precision levers can also motivate *tightening* the threshold as one of
  two responses ([reranker-vs-embeddings-roles.md](reranker-vs-embeddings-roles.md)).
