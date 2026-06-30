#!/usr/bin/env bash
# Deterministic gatekeeper + materializer: validate a reviewer proposal.json and
# write the surviving memories. The reviewer never writes files itself.
# Usage: materialize.sh <proposal.json> <session> <cwd>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1

P="${1:?proposal json}"; session="${2:-manual}"; cwd="${3:-$PWD}"
jq -e . "$P" >/dev/null 2>&1 || { log "materialize: invalid json $P"; exit 1; }

# Specific token shapes only — deliberately NO bare-hex rule (git SHAs are 40-hex).
SECRET='sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{24,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]'
kebab='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
yqs() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }   # YAML-safe quoted string

acc_m=0; rej_m=0; snapped_pre=0; wrote_active=0

# ── memories (cap 3) ─────────────────────────────────────────────────────────
mlen=$(jq '.memories|length' "$P" 2>/dev/null || echo 0)
for ((i=0; i<mlen && i<3; i++)); do
  m=$(jq -c ".memories[$i]" "$P")
  slug=$(printf '%s' "$m" | jq -r '.slug // empty')
  type=$(printf '%s' "$m" | jq -r '.type // empty')
  desc=$(printf '%s' "$m" | jq -r '.description // empty')
  body=$(printf '%s' "$m" | jq -r '.body // empty')
  why=$(printf '%s'  "$m" | jq -r '.why // empty')
  how=$(printf '%s'  "$m" | jq -r '.how_to_apply // empty')
  # repo is model-controlled → normalize to one safe token (basename, kebab-safe) so it can't leak a path or break YAML
  repo=$(printf '%s' "$m" | jq -r '.repo // ""' | tr -d '\n' | sed 's#.*/##' | tr -cd 'a-zA-Z0-9._-' | cut -c1-48)

  [[ "$slug" =~ $kebab ]] || { log "  reject mem (slug '$slug')"; rej_m=$((rej_m+1)); continue; }
  case "$type" in user|feedback|project|reference) ;; *) log "  reject mem $slug (type '$type')"; rej_m=$((rej_m+1)); continue;; esac
  { [ -n "$desc" ] && [ -n "$body" ] && [ -n "$why" ]; } || { log "  reject mem $slug (missing fields)"; rej_m=$((rej_m+1)); continue; }
  if printf '%s' "$body $desc" | grep -qiE "$SECRET"; then log "  reject mem $slug (secret-like)"; rej_m=$((rej_m+1)); continue; fi
  if [ -f "$MEMORY_DIR/$slug.md" ] || [ -f "$PENDING_MEM/$slug.md" ]; then log "  skip mem $slug (dup)"; rej_m=$((rej_m+1)); continue; fi

  full="$body"
  if [ "$type" = feedback ] || [ "$type" = project ]; then [ -n "$why" ] && full="$full"$'\n\n'"**Why:** $why"; fi
  [ -n "$how" ] && full="$full"$'\n'"**How to apply:** $how"

  if [ "$LOOP_MODE" = active ]; then
    [ "$snapped_pre" = 0 ] && { mem_snapshot "pre-materialize-$session"; snapped_pre=1; }
    dest="$MEMORY_DIR/$slug.md"; whyfile=""; wrote_active=1
  else dest="$PENDING_MEM/$slug.md"; whyfile="$PENDING_MEM/$slug.WHY.md"; fi
  mkdir -p "$(dirname "$dest")"
  { printf -- '---\n'; printf 'name: %s\n' "$slug"; printf 'description: %s\n' "$(yqs "$desc")";
    printf 'metadata:\n'; [ -n "$repo" ] && printf '  repo: %s\n' "$repo"; printf '  node_type: memory\n  type: %s\n  originSessionId: %s\n' "$type" "$session";
    printf -- '---\n\n'; printf '%s\n' "$full"; } > "$dest"
  [ -n "$whyfile" ] && printf 'source_session: %s\nrepo: %s\nwhy: %s\n' "$session" "$repo" "$why" > "$whyfile"
  if [ "$LOOP_MODE" = active ]; then
    grep -q "($slug.md)" "$MEMORY_DIR/MEMORY.md" 2>/dev/null || printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$desc" >> "$MEMORY_DIR/MEMORY.md"
  fi
  log "  +mem $slug -> ${dest#$HOME/}"; acc_m=$((acc_m+1))
done

[ "$wrote_active" = 1 ] && mem_snapshot "post-materialize-$session"
log "materialize: $session done mem(+$acc_m/-$rej_m) mode=$LOOP_MODE"
