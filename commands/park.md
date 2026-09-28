---
description: Write a resume checkpoint before stepping away, then advise compact/clear/leave-open
argument-hint: "[topic-slug]"
allowed-tools: Bash(bash:*), Bash(git:*), Read, Write, Edit
---

!`bash "$HOME/.claude/token-park-context.sh"`

Write a checkpoint so a **cold** session can pick this work up without re-reading it, then give a
one-line recommendation. This often runs unattended (the auto-park types `/park` into an idle
window), so never stop to ask unless a rule below says to. The user typed: **$ARGUMENTS**

## 1. Pick the file

One checkpoint per **topic** (existing ones are listed above), at
`$HOME/.claude/checkpoints/<basename of cwd>.<topic>.md`.

- **Argument given:** match it case-insensitively as a substring of the listed slugs. One match:
  name it and its age, get a yes, then overwrite. No match: new file under that slug. Several: list, ask.
- **No argument, this session continues a listed topic:** overwrite it, naming file and age in the reply.
- **No argument, new strand:** new kebab-case slug, 2-3 words about the work, never a date.
- **Never** overwrite another topic's file.

## 2. Write it

Everything is already in the window; do not read files to write this. If something needed is not
in the window, write "unknown" rather than reading. Pointers (`file:line`, commands, fileIDs), not
prose about code. **Under ~40 lines.** Omit any section that would be empty.

```markdown
<!-- park: session=<session id above> topic=<slug> -->
# <project> — <topic> — <YYYY-MM-DD HH:MM>

## Goal
<1-3 lines: what done looks like, and why>

## State
- <file:line / asset / command> — what changed; done | partial | broken
- git: <branch @ short HEAD, dirty?>   (omit outside a repo)

## Decided — do not reopen
- <decision> — <the reason, or the evidence that settled it>
- ruled out: <approach> — <why it failed>

## Verified vs assumed
- verified (<command / file:line>): ...
- assumed: ...

## Next
<the single next action, concrete enough to start cold — which file, which command>

## Waiting on the user
<questions or tests only the user can do; omit if none>
```

The `<!-- park: -->` line must be exact: `token-sessions.sh` matches it to the window.

**Decided — do not reopen** is the section that pays for the checkpoint. Catching up costs only ~7k
of tokens either way; what a cold session actually loses is *why* things are the way they are, and
it will reopen settled questions. That is rework, the top cost.

## 3. Recommend (one line)

Use the context figure printed above: **above ~80k → `/clear` after this**; below → leave it open.
If something is mid-flight that the checkpoint can't hold (a half-applied edit), say leave it open
instead. Parking without clearing always loses. Economics: CLAUDE.md, "Never park a large session".
Don't restate the checkpoint.
