# claude-loop

A **self-improving memory + skills loop for Claude Code**, native to the harness (no API keys — it rides your Claude subscription). It reviews your sessions, distills durable **memories** and reusable **skills**, validates them through a deterministic gatekeeper, and maintains the library over time — so Claude stops re-learning the same things.

## Quick start

```sh
git clone <this-repo> ~/git/claude-loop && cd ~/git/claude-loop
./claude-loop install                 # copy machinery, merge hooks, create runtime dirs
~/.claude/loop/bin/loopctl token            # optional: token for unattended cron
~/.claude/loop/bin/loopctl install-schedule # daily harvest + gardener (launchd, catches up after sleep)
~/.claude/loop/bin/loopctl enable           # start the per-session reviewer (stays dry-run)
~/.claude/loop/bin/loopctl mode active      # when you trust it: memories auto-write
```

Nothing is enabled silently. `./claude-loop install --link` symlinks the machinery instead of copying (edits in this repo go live — best for development).

## How it works

```
capture:  trigger → reviewer → proposal.json → gatekeeper → hot/cold store
recall:   prompt / subagent → retriever scores the store → injects pointers → you Read the file
maintain: nightly gardener curates both tiers
```

Memory lives in **two tiers**: a small **hot** index (`MEMORY.md`, auto-loaded every session — session-invariant rules, user/env, cross-cutting facts) and an unbounded **cold** archive (`ARCHIVE.md`, never auto-loaded — reached only by the retriever or grep). See [BEHAVIOR.md](BEHAVIOR.md) for what this feels like and [ARCHITECTURE.md](ARCHITECTURE.md) for the structure.

- **Triggers** — review at **session close** (`SessionEnd`), a daily **harvest** backstop, and a mid-session top-up every ~30 tool-calls (`REVIEW_EVERY_TOOLCALLS`, default `30`; opt out with `0`). Nothing fires until the loop is enabled — install never spends, and `loopctl enable` echoes the cadence — and rung-2 triage will make each top-up near-free. Watermarks advance only on a *successful* review, so a failed/API-errored run retries.
- **Reviewer** (Sonnet, read-only-ish): renders the **active branch only** of the transcript (drops Esc-Esc rewind forks, `isMeta` noise, harness wrappers; keeps subagent `Task` returns), judges **that slice alone** against the POLICY capture bar (it does not browse the store — dedup is the gatekeeper's job), and **writes a JSON proposal file** — it never writes real state.
- **Gatekeeper** (`materialize.sh`, bash+jq): validates slug/type/fields, scans for secrets, dedups, caps counts, **code-generates frontmatter**, and **routes each memory to a tier by type** (feedback/user → hot, reference/project → cold) in `memory-global` (optional `repo:` tag for later filtering — one store, no per-repo dirs). A guard aborts if the reviewer touched anything but its proposal.
- **Store** — `~/.claude/memory-global/` is a git repo; active-mode writes are snapshot-bracketed and `loopctl rollback`-able.
- **Retriever** — ships **disabled** behind **two independent switches, both required to inject**: (1) the loop enabled (`loopctl enable` → `LOOP_ENABLED=1`, plus `MEASUREMENT_ENABLED=1`; both default `0`), and (2) the prompt-submit / subagent-spawn gate rows flipped `shadow`→`live` (default `shadow`). `loopctl enable` sets only the first — so it alone does **not** inject. With both set, on prompt-submit and subagent-spawn a deterministic **BM25F** scorer ranks the whole store and injects the top **pointers, not bodies** — Claude Reads the file only if it's relevant. Why pointers, and how the scorer was chosen: [docs/decisions/](docs/decisions/).
- **Gardener** (Opus, daily): dedups, prunes, and re-verifies against live code; keeps the **hot** index within its budget by demoting reference-class entries to **cold** (rules are never demoted — they graduate upward), and curates cold. Never auto-edits skills. A run counts as done only if it wrote a fresh digest with no API error.
- **Self-heal** (gardener + skill-miner): a **missed** run (Mac asleep past its slot) or a **failed** one is re-run by a catch-up — fired from the nightly harvest *and*, the moment you're next active, from the `Stop` hook (sessions often stay open for days, so `SessionStart` alone would rarely fire; the catch-up rides every turn instead). The presence path (the `Stop` worker) is gated by an **atomic single-worker lock**, so at most one *detached* worker runs no matter how many turns fire it. The nightly harvest is a **separate entry** running the same due-checks — not behind that gate; instead the **store lock** serializes everything that mutates the store: in the catch-up **worker** garden runs **then** miner in sequence; the independently scheduled agents (gardener 03:00, miner 04:00) aren't coupled by an ordering lock — the **store lock** serializes any overlap (busy → **skip, not queue**) and the catch-up paths supply the retry, so no two paths overlap or starve each other. Each catch-up is independently gated to **≤ once / 2h**. `loopctl doctor` flags a stale/failed garden or a pending miner failure.
- **Review queue** — skills always stage for `/review-skills`; staged memories triage via `/review-memories`. A SessionStart line surfaces what changed since you were last here.

## Documentation map

One home per question — the files deliberately don't overlap (link, never duplicate):

| File | Question it answers |
|---|---|
| `ARCHITECTURE.md` | **What exists** — components, flows, invariants |
| `BEHAVIOR.md` | **What you experience** — what happens at each moment, what's human-gated, the knobs and vital signs |
| `POLICY.md` | **How the loop judges** — capture bar, tiers, curation rules (the prompts interpolate this file at runtime) |
| `docs/decisions/` | **Why it's this way, and how we know** — standalone decision records, one per file, each self-proving: context → decision → evidence → consequences |
| `backlog.md` (untracked) | Open decisions and working notes — private, never shipped |

Evidence rule for `docs/decisions/`: every claim cites its receipt (measurement, artifact hash, or experiment) or is explicitly marked unverified. Method, numbers, and artifact hashes ship; private fixtures and personal context never do (same boundary as the gitignored probe set).

## Commands

```
./claude-loop install [--link]    place machinery, merge hooks, create dirs
./claude-loop update              git pull + re-apply (idempotent)
./claude-loop uninstall [--purge] remove machinery + hooks + schedule (keeps your data unless --purge)
./claude-loop status              install state + health check

loopctl status | stats | doctor      observe
loopctl enable | disable | mode …     control
loopctl review-now                    review the current project's last session now
loopctl snapshot | rollback | mem-log memory-global git safety
loopctl install-schedule | token      unattended daily runs
```

## Config

`loop/config.sh` ships **defaults** (disabled, dry-run, models, cadence). Your machine-specific overrides live in `loop/config.local.sh` (gitignored, sourced last) — written by `loopctl enable|disable|mode`. So `update` brings new defaults without ever clobbering your tuning.

## Data & privacy

The repo contains **machinery only**. These are never committed (enforced by `.gitignore`) and stay on your machine:

- `loop/.env` — your subscription token
- `loop/config.local.sh` — your overrides
- `loop/{state,log,proposals,pending,archive}/` — runtime data
- `~/.claude/memory-global/` — your actual memories (a separate local git repo)

Sharing this repo shares the system, not your memories or secrets.

## Requirements

macOS (launchd scheduling), Claude Code, `jq`, `perl`, `/usr/bin/python3` (system python is fine).
