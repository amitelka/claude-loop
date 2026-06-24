#!/usr/bin/env bash
# Deterministic gatekeeper + materializer: validate a reviewer proposal.json and
# write the surviving memories/skills. The reviewer never writes files itself.
# Usage: materialize.sh <proposal.json> <session> <cwd>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1

P="${1:?proposal json}"; session="${2:-manual}"; cwd="${3:-$PWD}"
jq -e . "$P" >/dev/null 2>&1 || { log "materialize: invalid json $P"; exit 1; }

# Specific token shapes only — deliberately NO bare-hex rule (git SHAs are 40-hex).
SECRET='sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{24,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]'
kebab='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
yqs() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }   # YAML-safe quoted string

acc_m=0; rej_m=0; acc_s=0; rej_s=0; snapped_pre=0; wrote_active=0

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
  loc=$(printf '%s'  "$m" | jq -r '.install_location // "global"')

  [[ "$slug" =~ $kebab ]] || { log "  reject mem (slug '$slug')"; rej_m=$((rej_m+1)); continue; }
  case "$type" in user|feedback|project|reference) ;; *) log "  reject mem $slug (type '$type')"; rej_m=$((rej_m+1)); continue;; esac
  { [ -n "$desc" ] && [ -n "$body" ] && [ -n "$why" ]; } || { log "  reject mem $slug (missing fields)"; rej_m=$((rej_m+1)); continue; }
  if printf '%s' "$body $desc" | grep -qiE "$SECRET"; then log "  reject mem $slug (secret-like)"; rej_m=$((rej_m+1)); continue; fi
  if [ -f "$MEMORY_DIR/$slug.md" ] || [ -f "$PENDING_MEM/$slug.md" ]; then log "  skip mem $slug (dup)"; rej_m=$((rej_m+1)); continue; fi

  full="$body"
  if [ "$type" = feedback ] || [ "$type" = project ]; then [ -n "$why" ] && full="$full"$'\n\n'"**Why:** $why"; fi
  [ -n "$how" ] && full="$full"$'\n'"**How to apply:** $how"

  if [ "$LOOP_MODE" = active ] && [ "$loc" = global ]; then
    [ "$snapped_pre" = 0 ] && { mem_snapshot "pre-materialize-$session"; snapped_pre=1; }
    dest="$MEMORY_DIR/$slug.md"; whyfile=""; wrote_active=1
  else dest="$PENDING_MEM/$slug.md"; whyfile="$PENDING_MEM/$slug.WHY.md"; fi
  mkdir -p "$(dirname "$dest")"
  { printf -- '---\n'; printf 'name: %s\n' "$slug"; printf 'description: %s\n' "$(yqs "$desc")";
    printf 'metadata:\n  node_type: memory\n  type: %s\n  originSessionId: %s\n' "$type" "$session";
    printf -- '---\n\n'; printf '%s\n' "$full"; } > "$dest"
  [ -n "$whyfile" ] && printf 'source_session: %s\nrouting: %s\nwhy: %s\n' "$session" "$loc" "$why" > "$whyfile"
  if [ "$LOOP_MODE" = active ] && [ "$loc" = global ]; then
    grep -q "($slug.md)" "$MEMORY_DIR/MEMORY.md" 2>/dev/null || printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$desc" >> "$MEMORY_DIR/MEMORY.md"
  fi
  log "  +mem $slug -> ${dest#$HOME/}"; acc_m=$((acc_m+1))
done

# ── skills (cap 2) — ALWAYS staged to pending, never auto-installed ───────────
slen=$(jq '.skills|length' "$P" 2>/dev/null || echo 0)
for ((i=0; i<slen && i<2; i++)); do
  s=$(jq -c ".skills[$i]" "$P")
  name=$(printf '%s' "$s" | jq -r '.name // empty')
  desc=$(printf '%s' "$s" | jq -r '.description // empty')
  when=$(printf '%s' "$s" | jq -r '.when_to_use // empty')
  body=$(printf '%s' "$s" | jq -r '.body // empty')
  why=$(printf '%s'  "$s" | jq -r '.why // empty')
  loc=$(printf '%s'  "$s" | jq -r '.install_location // "global"')

  [[ "$name" =~ $kebab ]] || { log "  reject skill (name '$name')"; rej_s=$((rej_s+1)); continue; }
  { [ -n "$desc" ] && [ -n "$when" ] && [ -n "$body" ]; } || { log "  reject skill $name (missing fields)"; rej_s=$((rej_s+1)); continue; }
  if printf '%s' "$body $desc" | grep -qiE "$SECRET"; then log "  reject skill $name (secret-like)"; rej_s=$((rej_s+1)); continue; fi
  if [ -d "$SKILLS_DIR/$name" ] || [ -d "$PENDING_SKILLS/$name" ]; then log "  skip skill $name (dup)"; rej_s=$((rej_s+1)); continue; fi

  mkdir -p "$PENDING_SKILLS/$name"
  { printf -- '---\n'; printf 'name: %s\ndescription: %s\nwhen_to_use: %s\nuser-invocable: true\n' "$name" "$(yqs "$desc")" "$(yqs "$when")";
    printf -- '---\n\n'; printf '%s\n' "$body"; } > "$PENDING_SKILLS/$name/SKILL.md"
  printf 'source_session: %s\ninstall_location: %s\nwhy: %s\n' "$session" "$loc" "$why" > "$PENDING_SKILLS/$name/WHY.md"
  log "  +skill $name -> pending"; acc_s=$((acc_s+1))
done

[ "$wrote_active" = 1 ] && mem_snapshot "post-materialize-$session"
log "materialize: $session done mem(+$acc_m/-$rej_m) skill(+$acc_s/-$rej_s) mode=$LOOP_MODE"
