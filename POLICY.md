# POLICY — the loop's judgment layer

How the loop decides what to capture, which tier it lives in, and how it's curated. This file is the single
source for that judgment — the reviewer and gardener prompts both interpolate it at runtime, so edit here and
both move. Structure lives in `ARCHITECTURE.md`; thresholds and gates live in `loop/gates.tsv`.

## Tiers
- **Hot** (`MEMORY.md`) — auto-loaded into every session. Reserve for the session-INVARIANT: working-style
  rules, who the user is and their environment, and cross-cutting facts that could apply on any turn.
- **Cold** (`ARCHIVE.md`) — NOT auto-loaded; surfaced only by the retriever (pointer injection) or grep.
  Anything scoped to a specific tool, repo, task, or incident lives here. Cold is free; hot is a budget.
- **Hot criterion** — adjudicates the **reference class ONLY** (which cross-cutting reference earns hot):
  token-poor AND broadly-applicable → hot; well-tokened → cold, since its distinctive tokens (error strings,
  flags, nouns) let the retriever find it. **Rules (feedback) and user/env facts are hot BY TYPE,
  unconditionally — never subject to the token test.** A rule fires at moments that contain no query (nothing to
  retrieve against — "never push unasked" must already be in force at an unprompted push), so a demand-paged rule
  is off exactly when it matters. Rules leave hot only UPWARD, by graduation to the instruction layer — never
  down to cold.

## Capture bar (reviewer)
- Capture only what is durable (true beyond this session) AND non-obvious AND reusable. Most slices yield
  nothing — that is the correct, common result.
- Do NOT capture what the repo already records (code structure, git history, CLAUDE.md), nor anything that
  matters only to one conversation. Never capture secrets, tokens, or credentials.
- A `feedback` memory is a RULE in staging: capture it, tier it hot, and flag it as a graduation candidate —
  rules belong in the instruction layer, not permanently in memory.

## Descriptions are retrieval documents (write-side)
- The one-line description is both the injection payload and the retrieval surface. Phrase it by SYMPTOM and
  alias the vocabulary a future prompt would actually use — not a human-facing summary of the file.
- Preserve the distinctive tokens (exact error text, command and flag names, proper nouns). They are what the
  retriever matches on (matching is EXACT-token — BM25 weights matches by rarity and length, it does not find
  synonyms or word forms; "coroutines" ≠ "coroutine". If a future prompt would say it differently, write the
  alias INTO the description — aliasing at write time is how this system gets semantic breadth while matching
  stays exact. A token dropped from the description falls to body-weight ×1 if the body carries it, to ZERO if
  nowhere.); dropping them for brevity trades recall for bytes.

## Curation rules (gardener)
- **Demote, don't delete.** Deletion is reserved for WRONG content. For cold-eligible **reference/project**
  content: redundant-but-correct entries demote to cold (preserves provenance; cold is free), verifying
  "duplicated" at the token level first. Redundant **feedback/user** rules NEVER demote to cold — they merge with
  their sibling, or retire only after human-approved graduation to the instruction layer.
- **Generalize the claim, KEEP the tokens.** A merge may broaden the statement, but the merged body must
  retain every distinctive token from the originals — those tokens are the retrieval surface.
- **Tightening keeps tokens too.** Shortening an index line or description must preserve the retrieval tokens;
  compression that drops them trades recall for bytes.
- **Hot-budget moves are audited.** A cold→hot promotion (or any demotion outside the one-time migration) is a
  gardener action, logged to the actions sidecar (`action=promoted`/`demoted`) — hot is the one contended tier.
