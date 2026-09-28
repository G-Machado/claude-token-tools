---
description: Park, open a new window on /unpark <topic>, and make this one read-only
argument-hint: "[topic-slug]"
allowed-tools: Bash(bash:*), Bash(git:*), Bash(powershell:*), Read, Write, Edit
---

!`bash "$HOME/.claude/token-park-context.sh"`

Hand this work to a fresh window: checkpoint it, open a new terminal already running
`/unpark <topic>`, then block this window so the strand cannot fork. The user typed: **$ARGUMENTS**

Glue over pieces that already exist - do not reimplement any of them.

## 1. Park

Read `$HOME/.claude/commands/park.md` now (not from memory: it is the one source, and it changes)
and carry out its sections **1 and 2 only**, with `$ARGUMENTS` as its argument. Skip its section 3:
the advice is this command. Keep the slug you chose; the next steps need it.

## 2. Open the new window

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/token-unpark-new.ps1" -Topic <slug> -Cwd "<cwd above>" -OldSid <session id above>
```

It opens Windows Terminal (cmd as fallback) in that folder running `/unpark <slug>`, and sets this
session to `--extend 0` so nothing pays to keep it warm. Add `-Model <id>` only if the user named
one. **Exit 2** (`no checkpoint` / `no dir`) means nothing opened: report its output and stop -
do not block a window that has nowhere to hand off to.

## 3. Block this window

```
bash "$HOME/.claude/token-sessions.sh" --block <session id above> "handed off to /unpark <slug>"
```

`token-block.sh` runs on UserPromptSubmit, so it bites from the next prompt: every prompt is
refused and cut to the clipboard, `/exit` passes, and `u` in the widget lifts it to ask this
window something.

## 4. Reply

One line: the checkpoint file, that the new window is running `/unpark <slug>`, and that this
one is read-only now - close it, or `u` in the widget to consult it.
