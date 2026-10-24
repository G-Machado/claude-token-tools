---
description: Hand one self-contained task to a parallel session in a git worktree; this one stays live
argument-hint: "<topic-slug> [what to do]"
allowed-tools: Bash(bash:*), Bash(git:*), Bash(powershell:*), Read, Write, Edit
---

!`bash "$HOME/.claude/token-park-context.sh"`

Give one task to a new session that works it on its own branch in a git worktree and writes a
report, while this session carries on. Like `/handoff`, but nothing here is parked, blocked or
left to lapse. The user typed: **$ARGUMENTS**

Glue over pieces that already exist - do not reimplement any of them. If the task is not clear
from the argument and this window, or it is not self-contained (it needs decisions only this
window can make as it goes), say so and stop: a delegate cannot ask back.

## 1. Pick the names

- `<slug>`: the argument's first word if kebab-case, else a new 2-3 word slug for the task. It must
  not match a listed checkpoint, a `delegate/<slug>` branch (`git branch --list`) or an existing
  directory; on a clash say which and stop.
- `<root>`: `git rev-parse --show-toplevel`; `<sub>`: `git rev-parse --show-prefix` (cwd within it).
- `<worktree>`: `<root>/../<basename of root>-<slug>`; the delegate's cwd is `<worktree>/<sub>`.
- `<proj>`: the basename of the delegate's cwd (`/unpark` lists checkpoints by it). Equal to this
  one's unless `<sub>` is empty.

## 2. Write the brief

`$HOME/.claude/checkpoints/<proj>.<slug>.md`, in the checkpoint format of
`$HOME/.claude/commands/park.md` section 2 (read it now; it is the one source), with these changes:

- First line: `<!-- park: session=<this session id> topic=<slug> cwd=<delegate cwd> delegate-of=<this session id> -->`.
- **Next**: the task as concrete steps; **Stop after**: the done-criteria, checkable.
- **Goal** adds `Scope:` the files and dirs it may touch; everything else is read-only.
- **Decided** carries the constraints from this window the delegate must not reopen.
- **State**: `git: delegate/<slug> @ <HEAD short>`. The worktree starts at HEAD: **uncommitted
  work here is not in it.** If the task depends on it, say so and stop rather than delegate.
- **Waiting on the user**: none; a delegate that needs the user writes its report and stops.

## 3. Make the worktree

```
git -C "<root>" worktree add "<worktree>" -b delegate/<slug>
```

On failure, delete the brief and report the error.

## 4. Open the delegate

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/token-unpark-new.ps1" -Topic <slug> -Cwd "<delegate cwd, Windows form>" -Mode delegate -ParentSid <this session id>
```

No `-OldSid`: this tab is not taken over and this session is not set to lapse. `-ParentSid` only
logs the `open` event in `$HOME/.claude/token-delegate.log`. Add `-Model <id>`
only if the user named one. **Exit 2** means nothing opened: remove the worktree and branch
(`git worktree remove`, `git branch -D`), delete the brief, report its output.

## 5. Reply

One line: branch `delegate/<slug>`, the worktree path, and that the report will land at
`$HOME/.claude/checkpoints/reports/<proj>.<slug>.md` (a card in this tab in TokenChat). Then carry
on with whatever this session was doing.
