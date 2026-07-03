# Behavior

What using a Claude Code session wired to this loop actually feels like — the system from your chair.

> **Where this fits:** see the [Documentation map](README.md#documentation-map). This is the "what you
> experience" layer; structure, judgment, and the decision records each have their own home — linked where
> relevant, never restated here.

**Current state — ships dark.** Out of the box the retrieval/injection half neither scores nor logs:
`MEASUREMENT_ENABLED=0` and `LOOP_ENABLED=0`. Three states, each gated separately: (1) **dark** — both `0`,
the default; (2) both `1` with `gates.tsv` rows at `shadow` → **score + log only** (measurement, no injection);
(3) rows flipped `shadow`→`live` → **inject**. So everything below is what you get once it's fully enabled; by
default nothing here fires.

---

## At session start
Your hot memory index (`~/.claude/memory-global/MEMORY.md`) auto-loads into context, as it always has. What's
changed is *what's in it*: only the **session-invariant** — your working-style rules, who you are and your
environment, and cross-cutting facts that could apply on any turn. Everything scoped to one tool, repo, task,
or incident moved to a cold archive (`ARCHIVE.md`) that does **not** auto-load. The hot index stays small on
purpose — it's spent from a fixed token budget every single session, so it holds only what's worth that rent.
(Why a budget and not "load everything": [decisions/hot-cold-tiering.md](docs/decisions/hot-cold-tiering.md).)

## When you submit a prompt
A hook scores your prompt against the whole corpus (hot + cold) and, if something clears the bar, prepends a
short note: *"possibly relevant memories — read the file if it applies, ignore if not,"* then a pointer line
or two. **Pointers, not contents** — the loop hands you the index line, and you Read the actual file only if
it looks relevant. That keeps the nudge cheap (a line, not a page) and never feeds you a stale copy: you read
the memory's current source at the moment you need it. (Why pointers:
[decisions/pointer-injection-not-bodies.md](docs/decisions/pointer-injection-not-bodies.md).) A memory already
surfaced this session isn't repeated; that dedup resets after a context compaction, so a long session doesn't
permanently lose a pointer the compaction dropped.

## When you spawn a subagent
The same scoring runs on the subagent's task prompt, but the pointers are spliced into **the subagent's own
prompt** rather than your conversation — a hook that only added them to your side would never reach the child.
The subagent's other spawn parameters are preserved untouched. (How we verified where the text lands:
[decisions/subagent-inject-mechanism.md](docs/decisions/subagent-inject-mechanism.md).)

## Mid-turn (a later phase, still dark)
Three more gates are designed but not yet wired: a **friction** gate (surfaces a memory when a tool call errors),
a **seeking** gate (when you search), and a **hazard** gate (before a risky command). They come online one at a
time, each on its own shadow data and behind a per-turn injection cap, after the prompt/subagent gates have run
live for a while. A **warm-start** adjunct is also designed (not yet built): at session start in a known repo,
the loop may add its few active-state pointers — non-load-bearing.

## Pulling, not just pushing
Injection is the push; the corpus is always **pullable** too. Plain `grep` over the store works today; a
`loopctl search "<query>"` command is planned (Phase 3) as a thin wrapper over the same scorer; and peer tools
(via the share-memory pointer) can read or query the same corpus — one index, many readers.

## The write side — how memories get made and kept
You never hand-file a memory. A background **reviewer** runs at three moments — when a session closes, as a
mid-session top-up every ~20 tool calls, and a nightly backstop — reading the session and proposing durable,
non-obvious, reusable learnings; a deterministic gatekeeper (`materialize`) validates them, routes each to hot
or cold by type, and writes the file. A nightly **gardener** dedups, tightens, prunes wrong content, and can
promote a cold memory it judges broadly useful — every hot-budget move is logged. Both the reviewer and the
gardener are governed by the same `POLICY.md`, interpolated into their prompts so the rules can't drift between
them.

The loop **also** mines **skills** — memory is the primary output; skills are additional. From skill-usage telemetry and the memory corpus, a miner proposes
new skills or patches to existing ones — **always staged** to a pending queue for you to review via
`/review-skills`, never auto-installed or auto-edited. A SessionStart notice tells you when proposals (skills or
memories) are waiting.

## What runs when
- **Per finished session / on Stop:** the reviewer considers whether anything is worth capturing (usually not).
- **Nightly:** the gardener curates the whole store and rebuilds the retriever's index.
- **On any write, rollback, or install:** the derived index is rebuilt so retrieval never scores a stale corpus.

## What the loop will never do on its own
The loop **proposes; a human disposes** — scoped to what changes how you *work*:
- **Skills** are never auto-installed or auto-edited — the gardener only reports.
- **Instruction-layer changes** (graduating a rule into `CLAUDE.md`/output-style) are proposed, never written.
- **Turning injection on**, and each later gate flip, is a manual operator action.

**Memories are the exception, and deliberately so:** in active mode they auto-write — but they're *data*, not
behavior, and the write is mode-gated (dry-run stages to a queue instead), snapshot-bracketed, and
`loopctl rollback`-able. The human gate guards the irreversible or identity-shaping edits — the behavior-changing
ones above — because the loop edits its own inputs; a reversible data write doesn't need it.

## Knobs and vital signs
| Knob | Effect |
|---|---|
| `LOOP_ENABLED` | master switch; `0` = the whole loop is inert |
| `MEASUREMENT_ENABLED` | shadow logging on/off (independent kill switch) |
| `loop/gates.tsv` `mode` | per-gate `shadow` (log only) / `live` (inject) / `off` |

- `loopctl doctor` — hooks wired, schedule loaded, memory-global clean, index fresh vs stale.
- `loopctl stats` — reviewer/gardener/miner activity, regret count.
- **Cry-wolf read-rate** (post-flip) — how often an injected pointer actually gets Read. Sustained decay means
  the channel is losing credibility and a precision lever should fire.
- **Regret** — the gardener deleted a memory a later reviewer re-captured: a signal the deletion was wrong.
