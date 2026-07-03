# Decision: inject into a subagent via `updatedInput.prompt`, not `additionalContext`

**Status:** accepted (2026-07-03) · **Scope:** the subagent-spawn gate's inject mechanism.

## Context
The subagent-spawn gate scores a spawn's task prompt and should surface relevant memories **to the subagent** —
that's the entire point, since the subagent runs in an isolated context and can't see the parent's. The prompt/
submit gate injects via a hook returning `hookSpecificOutput.additionalContext`. The open question: on a
`PreToolUse` hook firing for a `Task`/`Agent` call, does `additionalContext` reach the **subagent**, or the
**parent** conversation?

## Decision
For subagent-spawn, inject by returning **`hookSpecificOutput.updatedInput`** with the memory pointers appended to
`tool_input.prompt` — the subagent's own prompt. `additionalContext` is **not** used here. Because `updatedInput`
**replaces the tool's arguments wholesale**, the hook rebuilds the *full* original `tool_input` and amends only
`.prompt`, so `subagent_type`, `description`, `model`, etc. survive untouched. This is expressed as data: a
per-row `inject = context | prompt` column in `gates.tsv`, so the engine stays generic and only the final emit
specializes.

## Evidence
Empirical, on Claude Code **2.1.199**, reproducible via `.backups/migration-harness/subagent-inject-probe.sh`
with the captured run preserved at `.backups/migration-harness/subagent-inject-evidence.txt`: a throwaway
`PreToolUse`/`Task` hook (loaded with `--settings` on the authed config, isolated cwd) both appended a unique
marker via `updatedInput.prompt` **and** emitted a second marker via `additionalContext`, then a real subagent
was spawned.

- The `updatedInput` marker appeared in the **subagent's own transcript**, as part of its first user message —
  i.e. `updatedInput.prompt` **is** spliced into the spawned agent's prompt.
- The `additionalContext` marker appeared **only in the parent** transcript (as the hook-response record),
  **never in the subagent** — confirming `additionalContext` on a Task hook lands in the caller, not the child.
- The current Claude Code hooks documentation is consistent (PreToolUse `additionalContext` is placed "next to
  the tool result," which for a Task call is the parent conversation).
- Standing regression: `loop/tests/injector_smoke_test.sh` asserts subagent-spawn emits `updatedInput` (not
  `additionalContext`), splices the pointer into `.prompt`, and preserves `subagent_type` + `description`.

## Consequences & triggers
- `updatedInput` being wholesale-replace is a **correctness hazard**: emitting only `{prompt: …}` would silently
  drop the other Task fields and break every spawn. The full-tool_input rebuild + the field-survival assertion in
  the smoke test are the guardrail.
- The per-session dedup and the threshold are shared with the prompt path; only the emit differs by the `inject`
  column, so both paths log and dedup identically.
- **CC-version dependency (drift risk).** This rests on Claude Code hook semantics — `updatedInput` on a Task
  `PreToolUse` hook — verified on 2.1.199; those can change across CC versions. Re-run the preserved probe on a
  version bump to re-verify. The standing runtime monitor is the **cry-wolf read-rate**, which captures subagent
  reads via `agent_id`: a silent regression (pointers stop reaching subagents) would surface as a decaying
  subagent-pointer read-rate.
