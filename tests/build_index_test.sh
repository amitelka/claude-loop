#!/usr/bin/env bash
# build_index.py: concurrent rebuilds to the same OUT must never corrupt or half-write the index. A fixed ".tmp"
# name would collide under overlap → FileNotFoundError, silent because the calling hook is fail-open (silent
# stale index). Guards the unique-temp + atomic-replace. Public-safe (synthetic corpus).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/mem"
printf '# Memory Index\n- [a](a.md) — alpha token\n- [b](b.md) — beta token\n' > "$tmp/mem/MEMORY.md"
printf 'body alpha content\n' > "$tmp/mem/a.md"; printf 'body beta content\n' > "$tmp/mem/b.md"
rc=0; ok(){ if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1' want '$2')"; rc=1; fi; }

# fire several concurrent builds at the same OUT
for _ in 1 2 3 4 5 6; do /usr/bin/python3 "$root/loop/bin/build_index.py" "$tmp/mem" "$tmp/out.json" >/dev/null 2>&1 & done
wait
ok "$(jq -e '.entries|length' "$tmp/out.json" >/dev/null 2>&1 && echo valid || echo corrupt)" valid "concurrent rebuilds → valid, non-torn JSON"
ok "$(jq -r '.entries|length' "$tmp/out.json" 2>/dev/null)" 2 "index has both entries"
ok "$(ls "$tmp"/.mem-index.*.tmp 2>/dev/null | wc -l | tr -d ' ')" 0 "no leftover temp files after concurrent builds"
exit "$rc"
