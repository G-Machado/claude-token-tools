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
prose about code. **Under ~50 lines.** Omit any section that would be empty.

The reader is a cold session that will act on it. Measured over 85 unparks (2026-10-04): reading the
checkpoint costs ~2.5k, but getting from there to the first edit costs a median 33.6k growth, 14.5k
output and 13 lookups, 58% of them on files the parked session had already read. Next, Map and Facts
exist to cut that: hand over the plan, the exact ranges and the facts, not a summary.

```markdown
<!-- park: session=<session id above> topic=<slug> cwd=<cwd above> -->
# <project> — <topic> — <YYYY-MM-DD HH:MM>

## Next
1. <first action: file:line or command, and the edit or answer it leads to>
2. <...the plan as far as this window already knows it>
Stop after: <the point where the cold session reports back>

## Goal
<1-2 lines: what done looks like, and why>

## Map — read these ranges, nothing else
- <file:start-end> — <what is there: symbol, its role in Next>
- not here: <places already searched that do not hold it>

## Facts
- <signature / return contract / constant / exact command the Next steps need>

## Decided — do not reopen
- <decision> — <the evidence that settled it> · assumes <premise>
- ruled out: <approach> — <why it failed>

## Verified vs assumed
- verified (<command / file:line>): ...
- assumed: ...
- open: <unknown> — check: `<the one command that settles it>`

## State
- <file:line / asset / command> — what changed; done | partial | broken
- git: <branch @ short HEAD, dirty?>   (omit outside a repo)

## Waiting on the user
<questions or tests only the user can do; omit if none>
```

- **Next** is the plan, not a hint: the steps this window would take next, in order, each concrete
  enough to start cold. After a `/handoff` the cold session runs them unasked unless Waiting on the
  user has items, so a step that needs the user's say belongs there, not in Next.
- **Map**: only what the Next steps touch, as line ranges seen in this window, at most 8 rows.
  `not here:` saves the cold session from searching the same places again.
- **Facts**: at most 10 lines, copied from the window, never recalled.
- **assumes**: name the premise a decision rests on when there is one (a price, a measured constant,
  a version). A later session may reopen the decision only if that premise has changed.
- **open**: an unknown without its one-command check is a search the cold session has to design.

The `<!-- park: -->` line must be exact: `token-sessions.sh` matches it to the window, and the
parked widget resumes in its `cwd=` (copy the path verbatim, spaces and all; it runs to ` -->`).

**Decided — do not reopen** is the section that guards against rework, the top cost: what a cold
session loses is *why* things are the way they are, and it will reopen settled questions. Next, Map
and Facts are what make catching up cheap.

## 3. Recommend (one line)

Use the context figure printed above: **above ~80k → `/clear` after this**; below → leave it open.
If something is mid-flight that the checkpoint can't hold (a half-applied edit), say leave it open
instead. Parking without clearing always loses. Economics: CLAUDE.md, "Never park a large session".
Don't restate the checkpoint.
