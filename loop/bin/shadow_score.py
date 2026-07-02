#!/usr/bin/env python3
# Lexical shadow retriever (measurement window B): term-overlap of the prompt against the MEMORY.md
# index (title + slug + description). Emits ONE json line to stdout — what a retriever WOULD inject
# (top-k slugs + scores + verdict), INCLUDING misses (verdict "no-match") so the mid-July re-probe has
# a denominator for precision/recall. Deterministic, explainable, no model in the path. Env in:
# MEM_INDEX (path to MEMORY.md), PROMPT, SID (session_id), PID (prompt_id), MV (schema version).
import os, re, sys, json, time

SCORER = "lex1"          # bump on ANY scoring-logic change so mixed regimes don't average together
TOPK, THRESHOLD = 3, 2   # a "hit" = top candidate shares >=THRESHOLD distinct tokens with the prompt
STOP = {"the","and","for","that","this","with","from","have","what","how","why","can","you","should",
        "would","could","are","was","not","but","its","use","using","get","let","see","need","the"}

def toks(s):
    return {t for t in re.split(r"[^a-z0-9]+", s.lower()) if len(t) >= 3 and t not in STOP}

q = toks(os.environ.get("PROMPT", ""))
scored = []
try:
    with open(os.environ.get("MEM_INDEX", "")) as f:
        for ln in f:
            m = re.match(r"\s*-\s*\[([^\]]*)\]\(([^)]+)\.md\)\s*[—-]*\s*(.*)", ln)
            if not m:
                continue
            title, slug, desc = m.group(1), m.group(2), m.group(3)
            score = len(q & (toks(title) | toks(slug.replace("-", " ")) | toks(desc)))
            if score:
                scored.append((score, slug))
except OSError:
    pass
scored.sort(key=lambda x: (-x[0], x[1]))
top = [{"slug": s, "score": sc} for sc, s in scored[:TOPK]]
verdict = "hit" if top and top[0]["score"] >= THRESHOLD else "no-match"
sys.stdout.write(json.dumps({
    "v": int(os.environ.get("MV", "1")), "scorer": SCORER, "stream": "shadow", "ts": int(time.time()),
    "session": os.environ.get("SID") or None, "prompt": os.environ.get("PID") or None,
    "nq": len(q), "top": top, "verdict": verdict}))
