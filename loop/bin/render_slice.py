#!/usr/bin/env python3
"""Render a RAW JSONL transcript slice (stdin) → compact reviewer transcript (stdout).

Improvements over the old jq renderer:
  - active branch only: walk parentUuid from the latest conversational entry; entries NOT on that
    ancestry chain are abandoned Esc-Esc rewind forks and are dropped (don't learn from discarded work)
  - drops isMeta entries (slash-command caveats, hook output, system reminders — not real turns)
  - strips harness wrapper tags embedded in real user turns (slash-command boilerplate, reminders)
  - keeps Task/Agent subagent FINAL returns in full; other tool_results stay truncated
"""
import sys, json, re

TASK_TOOLS = {"Task", "Agent"}
GENERIC_RESULT_CAP = 500
TASK_RESULT_CAP = 4000
TOOL_INPUT_CAP = 240

# Harness wrappers that show up inside real user turns but aren't the user's words.
NOISE = re.compile(
    "|".join([
        r"<command-name>.*?</command-name>",
        r"<command-message>.*?</command-message>",
        r"<command-args>.*?</command-args>",
        r"<local-command-stdout>.*?</local-command-stdout>",
        r"<local-command-stderr>.*?</local-command-stderr>",
        r"<local-command-caveat>.*?</local-command-caveat>",
        r"<system-reminder>.*?</system-reminder>",
    ]),
    re.DOTALL,
)

def clean_user(s):
    return NOISE.sub("", s or "").strip()

def clip(s, cap):
    s = s or ""
    return s if len(s) <= cap else s[:cap] + ("… [+%d chars truncated]" % (len(s) - cap))

entries = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except Exception:
        continue

# uuid -> parentUuid (for the active-branch ancestry walk)
parent = {e.get("uuid"): e.get("parentUuid") for e in entries if e.get("uuid")}
present = set(parent)

# tool_use_id -> tool name (to spot subagent Task returns)
tool_name = {}
for e in entries:
    content = (e.get("message") or {}).get("content")
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                tool_name[b.get("id")] = b.get("name")

# Active path = ancestry of the latest conversational entry (the slice's current tip).
conv = [e for e in entries if e.get("type") in ("user", "assistant")]
active = set()
if conv:
    cur, seen = conv[-1].get("uuid"), set()
    while cur and cur in present and cur not in seen:
        seen.add(cur); active.add(cur)
        cur = parent.get(cur)

out = []
for e in entries:
    if e.get("type") not in ("user", "assistant"):
        continue
    if e.get("isMeta") is True:
        continue
    uid = e.get("uuid")
    if active and uid is not None and uid not in active:
        continue  # off the active branch -> abandoned rewind fork
    role = e.get("type")
    content = (e.get("message") or {}).get("content")
    if isinstance(content, str):
        if role == "user":
            c = clean_user(content)
            if c:
                out.append("USER: " + c)
        continue
    if not isinstance(content, list):
        continue
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text":
            if role == "user":
                c = clean_user(b.get("text") or "")
                if c:
                    out.append("USER: " + c)
            else:
                out.append("ASSISTANT: " + (b.get("text") or ""))
        elif t == "tool_use":
            out.append("  → tool_call %s: %s" % (b.get("name", "?"), clip(json.dumps(b.get("input", {})), TOOL_INPUT_CAP)))
        elif t == "tool_result":
            cap = TASK_RESULT_CAP if tool_name.get(b.get("tool_use_id")) in TASK_TOOLS else GENERIC_RESULT_CAP
            c = b.get("content")
            out.append("  ↳ tool_result: " + clip(c if isinstance(c, str) else json.dumps(c), cap))

sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
