# tests/_setup.sh — shared sandbox + preflight for #23. NOT a *_test.sh (not globbed by run.sh).
# Source EARLY in every test:   . "$(dirname "$0")/_setup.sh"
# Exposes $tmp (a realpath'd temp dir) and exports CLAUDE_CONFIG_DIR=$tmp + LOOP_HOME=$tmp/loop so the loop's
# config.sh derives EVERY path under the sandbox — the store, state, profiles — never the operator's real
# ~/.claude or ~/.claude-loop. With LOOP_HOME=$tmp/loop, legacy $tmp/loop/{state,bin} refs still resolve; only
# the store moved (now $LOOP_HOME/memory-global, was $tmp/memory-global).
tmp="$(cd "$(mktemp -d)" && pwd -P)"   # realpath: //-scoped profile rules + macOS /tmp→/private/tmp symlink
export CLAUDE_CONFIG_DIR="$tmp"
export LOOP_HOME="$tmp/loop"
# PREFLIGHT — a test must NEVER touch a real home. Abort hard if the sandbox resolves to one, or escapes $tmp.
for _d in "$LOOP_HOME" "$CLAUDE_CONFIG_DIR"; do
  case "$_d" in
    "$HOME"|"$HOME/"|"$HOME/.claude"|"$HOME/.claude/"|"$HOME/.claude-loop"|"$HOME/.claude-loop/")
      echo "  FATAL preflight: sandbox '$_d' is a REAL home — ABORT" >&2; exit 99;;
  esac
  case "$_d" in "$tmp"|"$tmp"/*) ;; *) echo "  FATAL preflight: sandbox '$_d' escaped '$tmp' — ABORT" >&2; exit 99;; esac
done
trap 'rm -rf "$tmp"' EXIT