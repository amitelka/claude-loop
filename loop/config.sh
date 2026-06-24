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

# ── Bounds ────────────────────────────────────────────────────────────────────
MEMORY_INDEX_MAX_LINES=180

# ── Paths (honor CLAUDE_CONFIG_DIR so a temp install can be tested in isolation) ─
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOOP_DIR="$CLAUDE_HOME/loop"
MEMORY_DIR="$CLAUDE_HOME/memory-global"
SKILLS_DIR="$CLAUDE_HOME/skills"
PENDING_SKILLS="$LOOP_DIR/pending/skills"
PENDING_MEM="$LOOP_DIR/pending/memories"
STATE_DIR="$LOOP_DIR/state"
ARCHIVE_DIR="$LOOP_DIR/archive"
LOG="$LOOP_DIR/log/loop.log"
ENV_FILE="$LOOP_DIR/.env"

# ── Personal overrides (gitignored; win over the defaults above) ───────────────
[ -f "$LOOP_DIR/config.local.sh" ] && . "$LOOP_DIR/config.local.sh"
