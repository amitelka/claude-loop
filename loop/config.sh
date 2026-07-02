#!/usr/bin/env bash
# loop/config.sh — SHIPPED DEFAULTS. Do NOT put personal settings here.
# Your machine-specific overrides go in config.local.sh (gitignored, sourced last below),
# which `loopctl enable|disable|mode` writes to — so `update` never clobbers your tuning.

# ── Master switches ─────────────────────────────────────────────────────────
LOOP_ENABLED=0        # 0 = hooks no-op. Turn on with `loopctl enable`.
LOOP_MODE=dry-run     # dry-run: stage everything to pending. active: memories auto-write.

# ── Reviewer (per session-end; mid-session top-up every N tool-calls) ─────────
REVIEW_EVERY_TURNS=0        # 0 = off (SessionEnd captures non-tool content anyway)
REVIEW_EVERY_TOOLCALLS=20
REVIEWER_MODEL=sonnet
REVIEWER_EFFORT=high

# ── Gardener (daily maintenance) ──────────────────────────────────────────────
GARDENER_MODEL=opus
GARDENER_EFFORT=xhigh

# ── Skill miner (cross-corpus skill/patch proposer; manual or scheduled) ──────
SKILL_MINER_ENABLED=0          # 0 = no scheduled run; install-schedule skips it. Enable per machine.
SKILL_MINER_MODEL=opus
SKILL_MINER_EFFORT=high
SKILL_MINER_CADENCE_DAYS=7     # scheduled cadence; skip-if-unchanged makes most runs cheap no-ops
SKILL_MINER_ONLY_IF_CHANGED=1  # scheduled runs skip when inputs unchanged since last success (--force overrides)

# ── Bounds ────────────────────────────────────────────────────────────────────
MEMORY_INDEX_MAX_LINES=180

# ── Passive measurement (observation window B; log-only, never changes what Claude sees) ──
MEASUREMENT_ENABLED=0     # 0 = measurement hooks no-op. Enable per machine in config.local.sh.
MEASUREMENT_VERSION=1     # bump on any scorer/schema change so mid-window regimes don't mix in the logs

# ── Cross-agent: share memory-global into peer-agent homes (read-only; `loopctl share-memory`) ──
# :-separated peer home dirs (use $HOME/…, not ~). Adapter auto-detected per home: config.toml+auth.json
# → codex (writes an AGENTS.md memory-pointer); settings.json → claude (skipped — native auto-load already
# covers it); unknown → warned + skipped. The loop's own CLAUDE_HOME is never a target. "" = off; run bare
# and it defaults to ~/.codex if present.
SHARE_MEMORY_HOMES=""

# ── Paths (honor CLAUDE_CONFIG_DIR so a temp install can be tested in isolation) ─
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOOP_DIR="$CLAUDE_HOME/loop"
MEMORY_DIR="$CLAUDE_HOME/memory-global"
SKILLS_DIR="$CLAUDE_HOME/skills"
PENDING_SKILLS="$LOOP_DIR/pending/skills"
PENDING_MEM="$LOOP_DIR/pending/memories"
STATE_DIR="$LOOP_DIR/state"
MEASURE_DIR="$STATE_DIR/measure"   # passive-measurement jsonl streams (gitignored via loop/state/)
ARCHIVE_DIR="$LOOP_DIR/archive"
LOG="$LOOP_DIR/log/loop.log"
ENV_FILE="$LOOP_DIR/.env"

# ── Personal overrides (gitignored; win over the defaults above) ───────────────
[ -f "$LOOP_DIR/config.local.sh" ] && . "$LOOP_DIR/config.local.sh"
