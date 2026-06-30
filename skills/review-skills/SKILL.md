---
name: review-skills
description: Review, approve, or reject pending skill proposals staged by the self-improving loop in ~/.claude/loop/pending/skills. Use when the user wants to review pending skills, asks "what skills are pending", or responds to a session-start notice about skill proposals.
when_to_use: When there are pending loop-generated skill proposals to triage, or the user asks to review/approve/reject them.
user-invocable: true
---

# Review pending skill proposals

The self-improving loop stages candidate skills in `~/.claude/loop/pending/skills/<name>/`. Each dir has a `WHY.md` plus **either** `SKILL.md` (a brand-new skill) **or** `PATCH.md` (a proposed change to an existing installed skill). Walk the user through them and act on their decision.

## Steps
1. List proposals: `ls -d ~/.claude/loop/pending/skills/*/ 2>/dev/null`. If none, say so and stop.
2. For each pending dir, Read `WHY.md` and **either** `SKILL.md` (new skill) **or** `PATCH.md` (a patch — also Read the *installed* skill it targets, `~/.claude/skills/<name>/SKILL.md`, to judge the change in context). Present concisely: the name, new-skill-vs-patch, what it does / what the patch changes, the `repo` tag from `WHY.md`, and the source session + rationale.
3. Give your own quick read: is it genuinely reusable and correct, or thin/duplicative? Check it doesn't duplicate an existing skill (`ls ~/.claude/skills`).
4. Ask the user to approve or reject each (offer to batch).
5. On **approve**:
   - **new skill** (`SKILL.md`): `mv` the proposal dir to `~/.claude/skills/<name>/` (always global — any `repo` tag in `WHY.md` is advisory, never a separate location).
   - **patch** (`PATCH.md`): run `bash ~/.claude/loop/bin/loopctl skill-snapshot` first (so it's revertable via `loopctl skill-rollback`), then apply the change in `PATCH.md` to `~/.claude/skills/<name>/SKILL.md`, and remove the pending dir. If the target skill is a **symlink** (externally-managed, e.g. `external-skill`→its own repo), the edit lands in that repo — it's versioned there, not by `skill-rollback`.
   - Either way, drop the now-redundant `WHY.md`.
6. On **reject**: first record it so the miner won't re-derive it next run — `bash ~/.claude/loop/bin/loopctl skill-reject <name> <action>` (`<action>` is `patch` if the dir has `PATCH.md`, else `new`). Then move the proposal dir to `~/.claude/loop/archive/rejected/<name>-<date>/`. Archiving alone does **not** prevent re-proposal — the miner re-derives skills from memory each run, so `skill-reject` is what suppresses it (undo later with `loopctl skill-unreject <name> <action>`).
7. Summarize what was installed and what was archived.

Never auto-approve — always get the user's call. If a `SKILL.md` contains a secret or token, do not install it; flag it for the user.
