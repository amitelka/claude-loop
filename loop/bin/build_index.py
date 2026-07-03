#!/usr/bin/env python3
# Derived per-field token index for the retriever. Reads the store's index files (MEMORY.md = hot, ARCHIVE.md =
# cold) for the desc field + each memory's FULL FILE (YAML frontmatter + body) for the low-weight "b" field —
# universal frontmatter keys IDF-nullify, the repo tag stays as signal — tokenizes once, writes a flat JSON the scorer
# loads in O(ms). Rebuilt idempotently on write by materialize.sh / garden.sh — the hook NEVER reads N bodies
# per prompt. Gitignored (derived, rebuildable). Deterministic; no model.
import os, re, sys, json, hashlib, tempfile
MEMDIR = os.environ.get("MEMORY_DIR") or os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "memory-global")
OUT = os.environ.get("MEM_INDEX_JSON") or os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "loop/state/mem-index.json")
if len(sys.argv) > 1: MEMDIR = sys.argv[1]
if len(sys.argv) > 2: OUT = sys.argv[2]
STOP = {"the","and","for","that","this","with","from","have","what","how","why","can","you","should",
        "would","could","are","was","not","but","its","use","using","get","let","see","need"}
def toks(s):
    return sorted({t for t in re.split(r"[^a-z0-9]+", s.lower()) if len(t) >= 3 and t not in STOP})
INDEX_RE = re.compile(r"\s*-\s*\[([^\]]*)\]\(([^)]+)\.md\)\s*[—-]*\s*(.*)")
entries = {}
for idxfile in ("MEMORY.md", "ARCHIVE.md"):
    p = os.path.join(MEMDIR, idxfile)
    if not os.path.exists(p): continue
    for ln in open(p):
        m = INDEX_RE.match(ln)
        if not m: continue
        title, slug, desc = m.group(1), m.group(2), m.group(3)
        d = set(toks(title)) | set(toks(slug.replace("-", " "))) | set(toks(desc))
        b = set()
        bodyp = os.path.join(MEMDIR, slug + ".md")
        if os.path.exists(bodyp):
            try: b = set(toks(open(bodyp).read()))
            except OSError: pass
        entries[slug] = {"tier": "hot" if idxfile == "MEMORY.md" else "cold",
                         "d": sorted(d), "b": sorted(b)}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
payload = {"v": 1, "scorer_contract": "bm25f-1", "n": len(entries), "entries": entries}
blob = json.dumps(payload, separators=(",", ":"))
# atomic AND concurrency-safe: a UNIQUE temp in OUT's dir (a fixed ".tmp" collides under concurrent rebuilds →
# silent-stale-index since the hook is fail-open), then os.replace. A hook must never read a torn index mid-write.
with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(OUT) or ".", prefix=".mem-index.", suffix=".tmp", delete=False) as f:
    f.write(blob); tmp = f.name
os.replace(tmp, OUT)
print(f"mem-index.json: {len(entries)} entries ({sum(1 for e in entries.values() if e['tier']=='hot')} hot / "
      f"{sum(1 for e in entries.values() if e['tier']=='cold')} cold), {len(blob)} bytes, sha {hashlib.sha256(blob.encode()).hexdigest()[:12]} -> {OUT}")
