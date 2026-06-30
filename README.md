# hermes-infra

A **self-improving memory + skills loop for Claude Code**, native to the harness (no API keys — it rides your Claude subscription). It reviews your sessions, distills durable **memories** and reusable **skills**, validates them through a deterministic gatekeeper, and maintains the library over time — so Claude stops re-learning the same things.

## Quick start

```sh
git clone <this-repo> ~/git/hermes-infra && cd ~/git/hermes-infra
./hermes install                 # copy machinery, merge hooks, create runtime dirs
~/.claude/loop/bin/loopctl token            # optional: token for unattended cron
~/.claude/loop/bin/loopctl install-schedule # daily harvest + gardener (launchd, catches up after sleep)
~/.claude/loop/bin/loopctl enable           # start the per-session reviewer (stays dry-run)
~/.claude/loop/bin/loopctl mode active      # when you trust it: memories auto-write
```

Nothing is enabled silently. `./hermes install --link` symlinks the machinery instead of copying (edits in this repo go live — best for development).

## How it works

```
trigger → reviewer → proposal.json → gatekeeper → store → (recall) → gardener
```

- **Triggers** — review at **session close** (`SessionEnd`), a mid-session top-up every ~20 tool-calls, and a daily **harvest** backstop. Watermarks advance only on a *successful* review, so a failed/API-errored run retries.
- **Reviewer** (Sonnet, read-only-ish): renders the **active branch only** of the transcript (drops Esc-Esc rewind forks, `isMeta` noise, harness wrappers; keeps subagent `Task` returns), and **writes a JSON proposal file** — it never writes real state.
- **Gatekeeper** (`materialize.sh`, bash+jq): validates slug/type/fields, scans for secrets, dedups, caps counts, **code-generates frontmatter**, writes everything to `memory-global` (with an optional `repo:` tag for later filtering — one store, no per-repo dirs). A guard aborts if the reviewer touched anything but its proposal.
- **Store** — `~/.claude/memory-global/` is a git repo; active-mode writes are snapshot-bracketed and `loopctl rollback`-able.
- **Gardener** (Opus, daily): dedups/prunes/re-verifies against live code, enforces the `MEMORY.md` size cap. Never auto-edits skills. A run counts as done only if it wrote a fresh digest with no API error; a failed run (e.g. the Mac slept mid-request) self-heals — the next awake harvest re-runs it when >24h since the last confirmed success. `loopctl doctor` flags a garden stale >48h.
- **Review queue** — skills always stage for `/review-skills`; staged memories triage via `/review-memories`. A SessionStart line surfaces what changed since you were last here.

## Commands

```
./hermes install [--link]    place machinery, merge hooks, create dirs
./hermes update              git pull + re-apply (idempotent)
./hermes uninstall [--purge] remove machinery + hooks + schedule (keeps your data unless --purge)
./hermes status              install state + health check

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
