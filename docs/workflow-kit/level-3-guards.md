# Level 3 — guards and checkpoints

Builds on Level 2, because the scripts are already installed. Each guard is a separate hook, so
wire only the ones you want. Listed in priority order.

## The guards

| prio | hook | script | what it does |
|---|---|---|---|
| 1 | `UserPromptSubmit` | `token-gap-warn.sh` | after an idle gap on a big window, says so and pushes `/park` next time / compact now |
| 1 | `PreToolUse` (matcher `Read\|Bash`) | `token-readguard.js` | refuses a whole-file read over 500 lines once (Read, or a bare `cat` whose output reaches the model); the retry passes, so the model has to announce it |
| 2 | `PostToolUse` (matcher `*`) | `token-cycle-nudge.js` | once per prompt, when output passes 30k, tells the model to reach a clean point and stop; each fire is logged to `token-cycle-nudge.log`. `TOKEN_CYCLE_NUDGE=<n>` sets the bar, `0` turns it off |
| 2 | `UserPromptSubmit` | `token-block.sh` | refuses a prompt in two cases: above 300k context (only `/park` `/compact` `/clear` `/exit` pass), and typing into a **cold window above 97k**. In the cold case the prompt is copied to the clipboard, and `bash ~/.claude/token-sessions.sh --unblock` or the widget's `u` lifts the block. `TOKEN_COLD_BLOCK=0` turns the cold block off; `TOKEN_MAX_BLOCK=<n>` moves the hard stop |
| 3 | `SessionStart` | `token-warm-hint.sh` | on a new session, points out other sessions whose cache is still warm |
| 3 | `PreCompact` | `token-precompact-park.js` | writes a mechanical checkpoint before any compaction, because compaction drops rules |
| 3 | `SessionStart` | `token-compact-reinject.js` | after a compaction, re-injects that checkpoint |
| 3 | `UserPromptSubmit` | `token-me.js --line` | one `[widget]` line per prompt (context, cache, spend) for the model to act on |
| 3 | `SessionEnd` | `token-scorecard.js` | per-session grade against the targets |

All hooks use the same entry shape:

```json
{ "type": "command", "shell": "bash", "timeout": 10,
  "command": "bash \"$HOME/.claude/token-gap-warn.sh\"" }
```

- `.js` scripts run with `node "$HOME/.claude/<script>"`.
- Use `timeout: 5` for the `Read` guard and for `token-me.js`.
- Use `timeout: 15` for `PreCompact`.
- The full worked `settings.json` is in [../INSTALL.md](../INSTALL.md) §2.

## The commands

Installed by `install.sh` unless you pass `--no-cmds`.

| command | when |
|---|---|
| `/park` | before stepping away >1h above ~80k: writes a per-topic checkpoint (task, `file:line` state, verified vs assumed, next). Costs ~23k. **Follow it with `/clear`**: parking without clearing always loses |
| `/unpark <topic>` | first thing in the fresh window. Resumes from the checkpoint instead of re-deriving the context |
| `/handoff <topic>` | topic change, or same topic past ~150k: parks, opens a new window on `/unpark`, and makes the old window read-only |
| `/arc` | closes a work arc: updates the checkpoint's Decided / Verified / Next |
| `/tokens` | cost per prompt for this session |

`~/.claude/token-sessions.sh` lists every session on the machine with its context, idle time
and cache life. Read it before opening another session. `--checkpoints` lists what is parked.

## On returning to a session

| | cache warm | cache `COLD` |
|---|---|---|
| parked | carry on | above ~97k: `/clear` **before typing**, then `/unpark` (re-orientation costs ~34k with a checkpoint too) |
| not parked | carry on | above ~97k: `/clear` before typing and re-derive |

**Fable users:** a checkpoint is also the cheap way to move a task between models. `/park` in
the Opus session, then open Fable and run `/unpark <topic>`. Never run `/model` mid-session.
