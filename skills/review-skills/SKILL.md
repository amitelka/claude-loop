---
name: review-skills
description: Review, approve, or reject pending skill proposals staged by the self-improving loop in ~/.claude/loop/pending/skills. Use when the user wants to review pending skills, asks "what skills are pending", or responds to a session-start notice about skill proposals.
when_to_use: When there are pending loop-generated skill proposals to triage, or the user asks to review/approve/reject them.
user-invocable: true
---

# Review pending skill proposals

The self-improving loop stages candidate skills in `~/.claude/loop/pending/skills/<name>/` (each has `SKILL.md` + `WHY.md`). Walk the user through them and act on their decision.

## Steps
1. List proposals: `ls -d ~/.claude/loop/pending/skills/*/ 2>/dev/null`. If none, say so and stop.
2. For each, Read both `SKILL.md` and `WHY.md`. Present concisely: the skill name, what it does (description + the key steps), the `repo` tag (if any) from `WHY.md`, and the source session + rationale.
3. Give your own quick read: is it genuinely reusable and correct, or thin/duplicative? Check it doesn't duplicate an existing skill (`ls ~/.claude/skills`).
4. Ask the user to approve or reject each (offer to batch).
5. On **approve**: install to `~/.claude/skills/<name>/` (always global — any `repo` tag in `WHY.md` is advisory only, never a separate location); `mv` the proposal dir there. Drop the now-redundant `WHY.md` (or keep it inside — your call, but it isn't needed at runtime).
6. On **reject**: move the proposal dir to `~/.claude/loop/archive/rejected/<name>-<date>/` so it isn't re-proposed.
7. Summarize what was installed and what was archived.

Never auto-approve — always get the user's call. If a `SKILL.md` contains a secret or token, do not install it; flag it for the user.
