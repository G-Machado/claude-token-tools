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
   against a clear brief. Keep design, integration, merges and direction here. Run
   `node "$HOME/.claude/token-master.js" add-delegate <slug>` **first**: it admits or refuses
   (exit 3: >3 live, or the active account's 5-hour headroom under ~15% per delegate - the
   message names the fix: `cswap switch <n>`, retire one, wait). Six at once on 2026-11-10 put
   four into the limit. **Parallel only for a parallel resource**; otherwise rounds on one warm
   delegate.
   **Split a bundled ask into arcs** before delegating anything: review, then docs, then fixes,
   each with its own checkpoint and a handoff between (hand-off-ability 6 › time 3). One arc's
   lanes never start until the previous arc is integrated and parked.
3. **Pick model and effort per delegate** (`-Model` / `-Effort` on the open):
   | task | model | effort |
   |---|---|---|
   | grep-shaped output only: a list of paths, symbols, counts, with the check command in the brief | claude-haiku-5-5 | low |
   | anything that classifies, judges or writes prose (triage, audits, mechanical edits with a rule) | claude-sonnet-5-5 | medium |
   | a subsystem that cannot be split further (rare; say why in the brief) | claude-opus-5-5 | medium |
   Haiku's docs-audit lane (2026-11-10) returned false positives a sonnet lane would not have:
   its path check tried two prefixes and reported the rest missing. Haiku is for output the
   master verifies by running one command, not for judgement.
4. **Answer delegate questions.** TokenChat batches them: they reach you together as
   `[delegates ask] <slug>: Q1 ...`, one message per 15s. Answer each from the plan doc and Decided
   with `/answer <slug> <option label or text>`. TokenChat logs every answer
   (`token-master/log/<sid>.jsonl`) and answers a word-for-word repeat from the log without you;
   delegates read the log and Decided (`token-master.js decided`) before asking, so add to Decided
   only what the log line alone would not carry (the why, a rule wider than the question).
   **Escalate to the user only** what changes direction, scope or a Decided item: batch those on
   one AskUserQuestion card, then answer the delegate with what the user chose.
5. **Merge** a delegate's branch when its report lands. A clean report (`status=done stop=met`)
   arrives inline: `[delegate <slug> done, stop criteria met] Done: ... Merge: ...`. Merge from
   that; open the report only when a Done line does not fit the plan. Anything else arrives as
   "Read the delegate report": read it, then `git merge delegate/<slug>` or send it back with a
   new `/delegate`. **Integrate from summaries, never from raw lane output** (2026-11-11): a lane's
   file opens with its `## Summary` table (`commands/delegate.md`), and that table is all a
   master reads - `grep -A 45 '^## Summary'`. Whole reads of `_build/**` over 8 KB are refused in
   master mode (`token-readguard.js`, `token-guard.js`); a report without a Summary goes back for
   one. Session 9bde5243 read six lane files (14-34 KB each) into a 187k window and paid for
   them on every cycle after. To see what a live delegate is doing without its transcript:
   `token-sessions.sh --last <sid>` (last text + last tool, three lines). Read finished reports
   in one batch (the strip, or every DELEGATE DONE card together), not one per wakeup. A `--shared`
   delegate has no branch: review its changes in this checkout (`git diff -- <its Scope>`), then
   commit them with an explicit pathspec (`git commit -- <paths>`), never anything outside Scope.
   **Retire a delegate you will not message again** (parked and replaced, or done with nothing
   left to send it): `node "$HOME/.claude/token-master.js" retire <slug> [why]`. It finds the sid
   in this master's own records (a report's `for=`, a `token-delegate.log` row), so it never
   touches the user's own windows; runs `token-sessions.sh --extend <sid> 0` and `--block`; and
   drops the slug. Widget `u` or `--unblock` lifts the block. Tell the user to close the tab.

6. **A master's window stays ≤ 100k, and it hands off before integrating** (2026-11-11; KPI in
   `docs/COST-MODEL.md`). Integration is the master's one heavy step, so it starts in a fresh
   window: when the lanes are done, rewrite the plan doc with the Summary tables' ids, then
   `/handoff <topic>` - the new sid takes over (`token-master.js handover` keeps every earlier
   sid, so old briefs still resolve) and integrates at the floor instead of on top of the
   lane-management history. Past 100k mid-arc with delegates still working, `/compact <focus>`
   at the next clean point (same sid, delegates stay linked; the hook re-injects this plan) -
   give the focus text. Past 150k the sweep lets the window lapse on purpose (renew bar,
   `token-sessions.sh`) and the widget says "lapsing, unpark instead": park first. `/clear`
   gives a master a new sid with no lineage and orphans its delegates: never `/clear` a master,
   hand off instead. `token-master.js status` checks every delegate's link; a `BROKEN` line is
   yours to fix.
7. **Run an investigation as rounds on one warm delegate** (the A55 black screen, 2026-11-10:
   five rounds on one delegate found and confirmed it, with the user's eyes needed twice).
   - **Brief a pass test a machine can read**: a log line, a screenshot mean, an exit code. Rounds
     then run without the user; ask for the user's eyes only at the decision points.
   - **Send the next round with `SendMessage` to the same delegate** when
     `node "$HOME/.claude/token-master.js" warm <slug>` says `verdict=reuse` (alive, idle, under
     150k, cache >= 10 min). A new `/delegate` costs a cold start of ~50k.
   - **Subscribe once it is running**: send the task, wait until `token-sessions.sh --json` shows
     it `running`, then send a `notify_when_idle` with no message. A subscription sent while it is
     idle fires at once. Without one, its report wakes nothing and this window goes cold.
   - **Run the small decisive check yourself** (a grep, a setting read) between rounds when it
     explains the result. Send the loop work back to the delegate.
   - **Every report ends with "the cheapest next test"**, and the next round takes it. The order
     that works: bisect upward from a known-good minimal case, compare the outputs before adding
     more inputs, patch the artifact to confirm, then fix the source.
   - **Put what the user saw into the next task, word for word**, as evidence.
   - **Parallel delegates only for a parallel resource.** Find the serial one first (a project
     lock, one device, a chain of steps where each depends on the last).

## Unity: one Editor, ever

In a Unity project (`Assets/` + `ProjectSettings/`) there is exactly one Editor open. Never
suggest a second one, a worktree Editor, or a Library copy/junction.

- Editor work goes to `/delegate --shared`; worktree delegates only for Editor-free work.
- Scopes are disjoint per `.unity` scene and prefab across all live delegates.
- **Lease**: a FIFO lock in `node "$HOME/.claude/token-master.js" lease`, settled without you.
  Delegates queue with `lease take --wait` and release after each step. Take it yourself only for
  your own Editor step (`lease take --wait`, then `lease release`); never hold it idle. It covers
  writes under `Assets/` (a recompile disturbs everyone), scene open/switch, play mode, builds and
  tests; Unity CLI reads are free.
- `lease status` shows holder and queue; a live holder that forgot it: `lease release --force`.
  Never pass a lease wait to the user.
