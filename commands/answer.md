---
description: Master plan mode - answer a delegate's question
argument-hint: "<delegate-slug> <option label or free text>"
allowed-tools: Bash(node:*)
---

The user, or this master session, typed: **/answer $ARGUMENTS**

Run `node "$HOME/.claude/token-master.js" answer <slug> <text>`, with the first word as the slug and the
rest as the text. It writes `$HOME/.claude/token-master/answers/<slug>.json`. TokenChat answers the
delegate's held question with it. Prefer an option label the delegate offered, word for word. Free
text goes in as the "Other" answer.

Then add the answer to Decided in this master's plan doc, if it settles something a later delegate
would need. Reply in one line: `answered <slug>: <text>`.
