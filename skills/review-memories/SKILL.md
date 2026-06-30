---
name: review-memories
description: Review, approve, or reject pending memory proposals staged by the self-improving loop in ~/.claude/loop/pending/memories. Use to triage staged memories (especially in dry-run mode) instead of moving files by hand.
when_to_use: When there are staged memory proposals to promote/reject, or the user asks to review pending memories or runs /review-memories.
user-invocable: true
---

# Review pending memory proposals

The loop stages candidate memories in `~/.claude/loop/pending/memories/<slug>.md`, each with a `<slug>.WHY.md` sidecar (source session, intended routing, rationale). Walk the user through them and act on the decision — this replaces hand-moving files.

## Steps
1. List them: `ls ~/.claude/loop/pending/memories/*.md 2>/dev/null | grep -v '\.WHY\.md$'`. If none, say so and stop.
2. **Snapshot first** so every change is reversible: `bash ~/.claude/loop/bin/loopctl snapshot` (note the commit ref it prints).
3. For each memory, Read its `.md` and its `.WHY.md`. Present concisely: slug, `type`, the one-line description, a 1–2 line gist of the body, and from WHY — the `repo` tag (if any), source session(s), and rationale.
4. Give your own quick read: is it durable, non-obvious, reusable, and *still true*? Grep `~/.claude/memory-global/` to confirm it isn't a duplicate. Flag stale/contradicted ones — e.g. evolving-investigation snapshots — for re-verification before promoting.
5. Ask the user to approve / reject / skip each (offer to batch, e.g. "promote all", "reject the stale ones").
6. On **approve** (every memory goes to the global store — `repo` is only a tag, never a separate location):
   - `mv` the `.md` to `~/.claude/memory-global/<slug>.md`. If its WHY names a `repo` and the frontmatter has no `repo:` field yet, add `  repo: <name>` under `metadata:`.
   - Append a pointer to `~/.claude/memory-global/MEMORY.md`: `- [Title](<slug>.md) — <concise hook from its description>`. Keep MEMORY.md within its line cap (it auto-loads every session — see `MEMORY_INDEX_MAX_LINES` in `~/.claude/loop/config.sh`, currently 180); if near the cap, tighten/merge rather than just appending.
   - Move the `.WHY.md` to `~/.claude/loop/archive/promoted-why/`.
7. On **reject** → `mkdir -p ~/.claude/loop/archive/rejected` and move both `.md` and `.WHY.md` there.
8. On **skip** → leave in pending (it re-surfaces next time).
9. Summarize: promoted (with destinations), rejected, skipped — and remind the user that `loopctl rollback <ref>` (the snapshot from step 2) undoes the whole batch.

Never promote a memory containing a secret/token — flag it instead. Never delete; rejects are archived.
