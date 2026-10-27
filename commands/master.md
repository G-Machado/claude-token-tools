---
description: Master plan mode - plan and document here, delegate the token-heavy work, answer the delegates
argument-hint: "on [topic] [--live] | off | live on|off | status"
allowed-tools: Bash(node:*), Bash(bash:*), Bash(git:*), Bash(powershell:*), Read, Write, Edit
---

!`node "$HOME/.claude/token-master.js" status`

The user typed: **/master $ARGUMENTS**

## Switching

Run `node "$HOME/.claude/token-master.js" <args>` with the argument as typed (`on`, `off`,
`live on`, `live off`, `status`). For `on`:

- `<topic>`: the argument's first word after `on` if kebab-case, else this session's checkpoint
  topic if it has one, else a new 2-3 word slug for what this window is doing.
- Write the **plan doc** now if `$HOME/.claude/checkpoints/<proj>.<topic>.md` does not exist:
  the checkpoint format of `$HOME/.claude/commands/park.md` section 2 (read it; it is the one
  source). It is this master's checkpoint, so `/handoff` and TokenChat's plan chip read it as is.
- Pass `--plan <proj>.<topic>.md`, and `--live` if the user typed it.

Reply in one line: master on/off, live on/off, the plan doc path. On `live on`, add the cost: one
renewal an hour, about 0.05x of the window (at 150k, ~7.5k weighted an hour). It is kept warm only
while the machine is awake.

## While master mode is on (the status line above says `master`)

You are the planner and the integrator. The token-heavy, decision-free work goes to delegates.

1. **Keep the plan doc current**: Next as numbered steps, a step handed to a delegate marked
   `-> delegate/<slug>`, Decided growing with every answer. Rewrite it at each arc, not each turn.
2. **Delegate** with `/delegate <slug> <task>` anything bounded, token-heavy and free of
   direction decisions: scans, triage of logs and builds, mechanical edits, scoped implementation
   against a clear brief. Keep design, integration, merges and direction here. Then run
   `node "$HOME/.claude/token-master.js" add-delegate <slug>`.
3. **Pick model and effort per delegate** (`-Model` / `-Effort` on the open):
   | task | model | effort |
   |---|---|---|
   | wide scans, log/build triage, mechanical edits | claude-haiku-5-5 | low |
   | scoped implementation against a clear brief | claude-sonnet-5-5 | medium |
   | a subsystem that cannot be split further (rare; say why in the brief) | claude-opus-5-5 | medium |
4. **Answer delegate questions.** They reach you as `[delegate <slug> asks] ...`. Answer from the
   plan doc and Decided with `/answer <slug> <option label or text>`, then add the answer to
   Decided. **Escalate to the user only** what changes direction, scope or a Decided item: batch
   those on one AskUserQuestion card, then answer the delegate with what the user chose.
5. **Merge** a delegate's branch when its report lands: read the report, check the stop
   criteria, `git merge delegate/<slug>` or send it back with a new `/delegate`.
6. **Leave the window by handoff.** Past `TOKEN_MASTER_HANDOFF_AT` (default 200k), at the next
   clean point, rewrite the plan doc and offer `/handoff <topic>`. The new window takes the master
   over (`/unpark` runs `token-master.js handover`). `/compact` only if the user asks.
