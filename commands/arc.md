---
description: Close a work arc: delta-update the topic checkpoint (Decided / Verified / Next), no advice
argument-hint: "[topic-slug]"
allowed-tools: Bash(bash:*), Read, Edit, Write
---

!`bash "$HOME/.claude/token-park-context.sh"`

An arc just ended (a piece of work built, a question answered, a decision made). Fold what this arc
settled into the topic checkpoint so a `/compact` or `/clear` loses nothing, then carry on in the
same window. This is **not** `/park`: no full rewrite, no compact/clear advice. The user typed:
**$ARGUMENTS**

## 1. Pick the file

Same rules as `/park` step 1 (`$HOME/.claude/checkpoints/<basename of cwd>.<topic>.md`, match the
argument as a substring of the listed slugs, never touch another topic's file), except:

- **This session's topic already has a checkpoint:** use it without asking.
- **No checkpoint for this topic yet:** write a full one in the `/park` format
  (`~/.claude/commands/park.md` step 2), then stop. Still no advice.

## 2. Delta-update it

Read the checkpoint, then **Edit** it. Never rewrite the whole file. Work only from what is already in
the window; do not read other files to write this.

- **Stamp:** set `session=<session id above>` in the `<!-- park: -->` line and the time in the
  `#` heading. The compact re-inject hook finds the checkpoint by this stamp, so it must be current.
- **Decided — do not reopen:** append what this arc settled, with its reason, plus `ruled out:` lines
  for what was tried and dropped. Leave existing lines alone unless this arc overturned one on
  evidence; then replace it and say so in the reply.
- **Verified vs assumed:** add new lines. Move an `assumed:` line to verified only if this arc
  checked it, and name the command or `file:line` that did.
- **State:** edit only the bullets this arc changed. Add one for any new file.
- **Next:** replace it with the single next action.
- **Waiting on the user:** drop the items that got answered, add new ones.

Keep the whole file **under ~40 lines**: when it grows past that, compress older State bullets, not
Decided.

## 3. Reply (one or two lines)

Name the file and list what changed: `+N decided, +N verified, Next → <action>`. No advice on
compact or clear. The widget's ACTION line handles that, and heat decides what follows the arc.
