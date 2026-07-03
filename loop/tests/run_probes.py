#!/usr/bin/env python3
# Canonical hermetic probe runner (becomes the probes-CI harness). Exports memory-global at a PINNED rev to a
# temp dir (no live ~/.claude paths), runs one scorer over probes.jsonl, emits a self-describing artifact:
# {memory_rev, scorer path+sha+stamp, topk, per-probe rank/score/margin/tie, recall@1/@3, per-bucket residency vs
# scorer-hit}. Usage: run_probes.py --rev REV --probes F --scorer S [--env K=V,...] [--topk N] --out ART
import argparse, subprocess, json, os, tempfile, hashlib, shutil, sys
ap=argparse.ArgumentParser()
ap.add_argument("--rev",required=True); ap.add_argument("--probes",required=True)
ap.add_argument("--scorer",required=True); ap.add_argument("--memrepo",default=os.path.expanduser("~/.claude/memory-global"))
ap.add_argument("--env",default=""); ap.add_argument("--topk",type=int,default=8); ap.add_argument("--out",required=True)
a=ap.parse_args()
extra=dict(kv.split("=",1) for kv in a.env.split(",") if kv)
tmp=tempfile.mkdtemp(prefix="probes-hermetic-")
try:
    # hermetic export of the pinned rev (tree only, no live paths)
    tar=subprocess.run(["git","-C",a.memrepo,"archive",a.rev],capture_output=True,check=True).stdout
    subprocess.run(["tar","-x","-C",tmp],input=tar,check=True)
    # build the derived index over the exported tree with the SHIPPED builder (sibling of the scorer); the scorer
    # reads MEM_INDEX_JSON and never memory files, so probes-CI must exercise the same build_index→score plumbing
    builder=os.path.join(os.path.dirname(os.path.abspath(a.scorer)),"build_index.py")
    idxjson=os.path.join(tmp,"mem-index.json")
    subprocess.run(["/usr/bin/python3",builder,tmp,idxjson],check=True)
    sha=hashlib.sha256(open(a.scorer,"rb").read()).hexdigest()[:12]
    probes=[json.loads(l) for l in open(a.probes) if l.strip()]
    per=[]
    for pr in probes:
        env={**os.environ,"MEM_INDEX_JSON":idxjson,"TOPK":str(a.topk),"MV":"1",**extra}
        r=subprocess.run(["/usr/bin/python3",a.scorer],input=pr["prompt"],capture_output=True,text=True,env=env)
        try: top=json.loads(r.stdout).get("top",[])
        except: top=[]
        exp=pr["expected"]
        ranks=[i+1 for i,t in enumerate(top) if t["slug"] in exp]
        erank=min(ranks) if ranks else None
        margin=(top[2]["score"]-top[3]["score"]) if len(top)>=4 else None
        tie=(len(top)>=4 and top[2]["score"]==top[3]["score"])
        per.append({"id":pr["id"],"bucket":pr["bucket"],"conceptual":pr.get("conceptual",False),
                    "expected":exp,"top3":[{ "slug":t["slug"],"score":t["score"]} for t in top[:3]],
                    "erank":erank,"escore":(top[erank-1]["score"] if erank else None),
                    "hit1":erank==1,"hit3":(erank is not None and erank<=3),
                    "top1_slug":(top[0]["slug"] if top else None),"top1_score":(top[0]["score"] if top else 0),
                    "cutoff_margin":margin,"tie_at_cutoff":tie})
    pos=[p for p in per if p["bucket"] in ("HOT-RES","ACTIVE","COLD")]
    buckets={}
    for bk in ("HOT-RES","ACTIVE","COLD"):
        b=[p for p in pos if p["bucket"]==bk]
        buckets[bk]={"n":len(b),"scorer_hit3":sum(p["hit3"] for p in b),
                     "residency":(len(b) if bk=="HOT-RES" else None)}  # HOT-RES resident by construction
    art={"memory_rev":a.rev,"scorer":os.path.basename(a.scorer),"scorer_sha":sha,"topk":a.topk,"env":extra,
         "n_pos":len(pos),"recall_at_1":sum(p["hit1"] for p in pos),"recall_at_3":sum(p["hit3"] for p in pos),
         "buckets":buckets,"per_probe":per}
    # precision arm folded into the canonical artifact (codex HIGH): NEG false-inject + threshold sweep
    neg=[p for p in per if p["bucket"]=="NEG"]
    pe=[p["escore"] for p in pos if p["hit3"]]
    nts=sorted([p["top1_score"] for p in neg],reverse=True)
    cand=sorted(set([round(x,2) for x in pe]+[round(x,2) for x in nts]))
    sweep=[{"T":T,"recall":sum(1 for s in pe if s>=T),"false_inject":sum(1 for s in nts if s>=T)} for T in cand]
    art["metric_k"]=3
    art["precision"]={"n_neg":len(neg),
                      "negatives":[{"id":p["id"],"top1_slug":p["top1_slug"],"top1_score":p["top1_score"]} for p in neg],
                      "sweep":sweep}
    json.dump(art,open(a.out,"w"),indent=1)
    print(f"{a.out}: scorer={art['scorer']} sha={sha} rev={a.rev[:7]} recall@3={art['recall_at_3']}/{art['n_pos']} "
          f"HOT-RES hit3={buckets['HOT-RES']['scorer_hit3']}/{buckets['HOT-RES']['n']} "
          f"ACTIVE {buckets['ACTIVE']['scorer_hit3']}/{buckets['ACTIVE']['n']} COLD {buckets['COLD']['scorer_hit3']}/{buckets['COLD']['n']}")
finally:
    shutil.rmtree(tmp,ignore_errors=True)
