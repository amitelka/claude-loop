#!/usr/bin/env python3
# THE retriever scorer (bm25f-1). BM25F over the derived per-field token index (build_index.py): desc field
# boosted high, low-weight "b" field = the memory's FULL FILE (frontmatter + body; universal keys IDF-nullify).
# Reads the prompt on stdin + the precomputed index (MEM_INDEX_JSON) — it never
# re-reads memory files, so it is O(ms) in a hook. Emits ONE json line: top-k pointer candidates + scores + tier
# + verdict, INCLUDING misses (the denominator). Deterministic, no model. One scorer, no forks — consumed by the
# gate-runner (injection), recall-probe, and the probes-CI runner. The A/B-tested artifact IS this file.
import os, re, sys, json, time, math
SCORER = "bm25f-1"                       # bump on ANY scoring change so shadow logs never mix regimes
TOPK = int(os.environ.get("TOPK", "3"))
K1, B = 1.2, 0.75
BOOST = {"d": 3.0, "b": 1.0}             # desc high / body low — a-priori field ruling, NOT probe-tuned
STOP = {"the","and","for","that","this","with","from","have","what","how","why","can","you","should",
        "would","could","are","was","not","but","its","use","using","get","let","see","need"}
def toks(s):
    return {t for t in re.split(r"[^a-z0-9]+", s.lower()) if len(t) >= 3 and t not in STOP}
IDXPATH = os.environ.get("MEM_INDEX_JSON") or os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "loop/state/mem-index.json")
try:
    idx = json.load(open(IDXPATH)).get("entries", {})
except Exception:
    idx = {}
N = len(idx) or 1
df = {}
for e in idx.values():
    for t in set(e["d"]) | set(e["b"]):
        df[t] = df.get(t, 0) + 1
avgd = (sum(len(e["d"]) for e in idx.values()) / N) or 1
avgb = (sum(len(e["b"]) for e in idx.values()) / N) or 1
def idf(t):
    n = df.get(t, 0); return math.log(1 + (N - n + 0.5) / (n + 0.5))
q = toks(sys.stdin.read())
scored = []
for slug, e in idx.items():
    D, Bset = set(e["d"]), set(e["b"])
    inter = q & (D | Bset)
    if not inter:
        continue
    sc = 0.0
    for t in inter:
        wtf = 0.0
        if t in D:    wtf += BOOST["d"] / (1 - B + B * len(D) / avgd)
        if t in Bset: wtf += BOOST["b"] / (1 - B + B * len(Bset) / avgb)
        sc += idf(t) * (wtf * (K1 + 1)) / (wtf + K1)
    scored.append((sc, slug, e.get("tier")))
scored.sort(key=lambda x: (-x[0], x[1]))
top = [{"slug": s, "score": round(sc, 3), "tier": tier} for sc, s, tier in scored[:TOPK]]
sys.stdout.write(json.dumps({
    "v": int(os.environ.get("MV", "1")), "scorer": SCORER, "stream": "shadow", "ts": int(time.time()),
    "session": os.environ.get("SID") or None, "prompt": os.environ.get("PID") or None,
    "nq": len(q), "top": top, "verdict": "hit" if top else "no-match"}, separators=(",", ":")))
