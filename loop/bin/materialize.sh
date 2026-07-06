#!/usr/bin/env bash
# Deterministic gatekeeper + materializer: validate a reviewer proposal.json and
# write the surviving memories. The reviewer never writes files itself.
# Usage: materialize.sh <proposal.json> <session> <cwd>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" 2>/dev/null || exit 1

P="${1:?proposal json}"; session="${2:-manual}"; cwd="${3:-$PWD}"
jq -e . "$P" >/dev/null 2>&1 || { log "materialize: invalid json $P"; exit 1; }

# Exit contract (#16 P0-h): review.sh advances the watermark ONLY on landed(0)/clean-noop(10). deferred(20) =
# store busy after bounded retries; failed(30) = write reverted/quarantined. Both retry (harvest backstops).
EX_LANDED=0; EX_NOOP=10; EX_DEFERRED=20; EX_FAILED=30
pre_rev=""; wrote_slugs=()
if [ "$LOOP_MODE" = active ]; then
  # #23 lock-shrink: review no longer holds the store lock across its model run — materialize ALWAYS acquires its
  # OWN lock (bounded wait; the reviewer already spent ~$0.43, so retry a few times before deferring) and re-ingests
  # + re-validates immediately before writing, so a peer write during the review window only makes the proposal
  # stale (dedup/validate here catches it). Give-up = DEFERRED → no watermark advance; harvest retries.
  acquire_store_lock_wait "materialize-$(sanitize_sid "$session")" "${MATERIALIZE_LOCK_TRIES:-3}" "${MATERIALIZE_LOCK_SLEEP:-5}" \
    || { log "materialize: store busy after retries ($session) — DEFERRED, no advance"; exit $EX_DEFERRED; }
  trap 'release_store_lock' EXIT
  ing="$(ingest_external)"; [ "$ing" = clean ] || log "materialize: entry ingress=$ing ($session)"   # re-ingest pre-existing dirt (incl. any peer write during the review window)
  pre_rev="$(mem_git rev-parse HEAD 2>/dev/null)"   # explicit-path commit reference (replaces the pre-materialize snapshot)
fi

# Specific token shapes only — deliberately NO bare-hex rule (git SHAs are 40-hex).
SECRET='sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{24,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]'
kebab='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
yqs() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }   # YAML-safe quoted string

acc_m=0; rej_m=0; wrote_active=0

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
    dest="$MEMORY_DIR/$slug.md"; whyfile=""; wrote_active=1; wrote_slugs+=("$slug")
  else dest="$PENDING_MEM/$slug.md"; whyfile="$PENDING_MEM/$slug.WHY.md"; fi
  mkdir -p "$(dirname "$dest")"
  { printf -- '---\n'; printf 'name: %s\n' "$slug"; printf 'description: %s\n' "$(yqs "$desc")";
    printf 'metadata:\n'; [ -n "$repo" ] && printf '  repo: %s\n' "$repo"; printf '  node_type: memory\n  type: %s\n  originSessionId: %s\n' "$type" "$session";
    printf -- '---\n\n'; printf '%s\n' "$full"; } > "$dest"
  [ -n "$whyfile" ] && printf 'source_session: %s\nrepo: %s\nwhy: %s\n' "$session" "$repo" "$why" > "$whyfile"
  if [ "$LOOP_MODE" = active ]; then
    # Tier routing (POLICY.md, Option B — deterministic by type): feedback|user = session-invariant → hot
    # (MEMORY.md); reference|project = cold → ARCHIVE.md. The gardener promotes the rare cross-cutting ref.
    case "$type" in feedback|user) idxfile="$MEMORY_DIR/MEMORY.md";; *) idxfile="$MEMORY_DIR/ARCHIVE.md";; esac
    grep -q "($slug.md)" "$idxfile" 2>/dev/null || printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$desc" >> "$idxfile"
  fi
  log "  +mem $slug -> ${dest#$HOME/}"; acc_m=$((acc_m+1))
  # Regret signal: the gardener deleted this exact slug in a past run (garden-actions sidecar) and the
  # reviewer just re-captured it → the prune was probably wrong. Detection only (we still wrote it above);
  # exact-slug for now, near-match (reworded recaptures) is deferred to NEXT#5b's cross-source dedup.
  grep -q "\"action\":\"deleted\",\"slug\":\"$slug\"" "$STATE_DIR/garden-actions.jsonl" 2>/dev/null \
    && log "  regret $slug (gardener pruned it earlier; reviewer re-captured)"
done

rc_out=$EX_NOOP   # default: ran fine, wrote nothing to the store (all dups/rejects, or pending mode) → advance
if [ "$wrote_active" = 1 ]; then
  # Post-write integrity gate (2a): a deterministic append shouldn't corrupt the index, but assert it — on
  # failure, do NOT commit; restore to pre_rev and quarantine the proposal (doctor-visible tag).
  if vreason="$(validate_store "$MEMORY_DIR")"; then
    # EXPLICIT-path commit (P0-c, never add -A): exactly the written bodies + the two indexes. A peer BODY write
    # between validate and commit can't ride in (not in the explicit set). DOCUMENTED residual (xhigh): a peer write
    # to an INDEX file in that window rides inside the staged index — bounded to the 2 indexes, non-poison, nightly-reviewed.
    cpaths=(MEMORY.md ARCHIVE.md); for s in "${wrote_slugs[@]}"; do cpaths+=("$s.md"); done
    mem_git add -- "${cpaths[@]}" >/dev/null 2>&1
    mem_git commit -qm "materialize-$session $(date '+%Y-%m-%dT%H:%M:%S')" >/dev/null 2>&1
    rebuild_mem_index "materialize $session"   # derived retriever index; stale index self-heals next write
    rc_out=$EX_LANDED
  else
    mkdir -p "$QUARANTINE_DIR"; q="$QUARANTINE_DIR/materialize-$(sanitize_sid "$session")-$(date +%s)"
    cp "$P" "$q.json" 2>/dev/null; printf 'validate:%s\nsession:%s\n' "$vreason" "$session" > "$q.reason"
    mem_restore_to "$pre_rev" "$q.patch"   # discard the bad write → HEAD stays at the (valid) pre-materialize rev
    log "materialize: quarantine $session (validate:$vreason) — write reverted, proposal saved to ${q#$HOME/}.json"
    rc_out=$EX_FAILED
  fi
fi
log "materialize: $session done mem(+$acc_m/-$rej_m) mode=$LOOP_MODE rc=$rc_out"
exit $rc_out
