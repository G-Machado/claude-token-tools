---
description: Resume from a parked checkpoint after a /clear, without re-deriving the session
allowed-tools: Bash(bash:*), Bash(git:*), Read, Grep, Glob
---

!`bash "$HOME/.claude/token-unpark-context.sh"`

Resume the work a previous session parked. The checkpoints for this project are listed above, newest
first, with topic slug, age, and full path. The user typed: **$ARGUMENTS**

A trailing `--handoff` is not part of the topic: drop it before matching. It means `/handoff` opened
this window mid-flow; nobody cleared to go elsewhere. A trailing `--delegate` is dropped the same
way: `/delegate` opened this window in a git worktree to do one task while the parent stays live.

**Pick one, in this order.**

1. **An argument was given** — match it case-insensitively against the topic slugs as a substring
   (`thruster` matches `thruster-flame`, `scan` matches `radar-scan`). Exactly one match: read it and
   go, no questions. Several matches: list just those and ask. No match: say so plainly and list what
   *is* there — never fall back to "closest" or to the newest, which is how you resume the wrong
   strand while sounding confident.
2. **No argument, one checkpoint listed** — read it and go.
3. **No argument, several listed** — this project runs parallel sessions, so several is normal, not a
   problem to solve by guessing. List the topics with their ages, one line each, and ask which.
   Picking wrong costs a whole session of work in the wrong strand, which is the one thing more
   expensive than asking.
4. **Nothing listed for this project** — say so and show what `--checkpoints all` returns. Do not
   invent a starting point.

**Then check it against reality before trusting it.**

A checkpoint records what was true when it was written; the tree may have moved since, via another
session, another developer, or the user's own hands.

- Compare its recorded branch and HEAD against the `NOW` line above. If they differ, say so before
  anything else — it is describing a state that no longer exists.
- Keep its **verified** claims verified and its **assumed** claims assumed. Do not promote one to the
  other by re-reading.
- If it names a file, function or flag, confirm that still exists before recommending it — one `ls`
  or `grep -n` over the Map rows, not a read.

**Then report and stop — or, after a handoff, carry on.**

- **Plain `/unpark`:** report in three lines — where the work stands, the first Next step, anything
  blocked or open — and stop. Do not begin until the user says to: they cleared for a reason and may
  want to go elsewhere.
- **`--handoff`, Waiting on the user empty or absent, the checks above clean:** one line on where it
  stands, then run the Next steps in order up to its `Stop after:` point, and report there.
- **`--handoff` from a master** (`node "$HOME/.claude/token-master.js" status --sid <the header's
  session=>` says `master`): first run `node "$HOME/.claude/token-master.js" handover <that sid>`.
  This window is the master now, live if the old one was, and its delegates answer to it.
  Follow `commands/master.md` from here.
- **`--handoff` with anything waiting on the user, or a check failed:** report in three lines and
  stop, with the waiting items as the `▶` block.
- **`--delegate`:** as `--handoff`, except the branch is expected to be `delegate/<topic>` at the
  checkpoint's HEAD (that is not a failed check), and:
  - Touch only what its Scope names; commit only on this branch, in this worktree, never push.
  - Header has `master=`: an open question goes to the master as an AskUserQuestion card (one
    question, options first). Wait for its answer, which arrives as the card's answer, and carry
    on. Never ask what the brief or Decided already settles.
  - At `Stop after:` (or when blocked), write `$HOME/.claude/checkpoints/reports/<checkpoint file name>`
    (`mkdir -p` it; the subfolder keeps reports out of the Parked list) and stop. Its first line: `<!-- report: for=<delegate-of sid> sid=<this session id> topic=<slug>
    branch=<branch> worktree=<cwd> -->` on one line (`echo $CLAUDE_CODE_SESSION_ID` gives this id;
    the cost analysis joins on it), then a **Done** list (`file:line` — clause), **Basis** (verified vs
    assumed), **Blocked** if any, and **Merge**: `git merge delegate/<slug>` from the parent tree,
    then `git worktree remove <worktree>` and `git branch -d delegate/<slug>`.
  - Reply with one line: the report path. The parent picks it up from there.

**Working from it.** Read the Map ranges only when a Next step needs them, as ranged reads; skip the
`not here:` places and use Facts instead of reading. An `open:` line comes with its check: run that
command rather than searching. Do not re-read the files the checkpoint summarises.

Treat **Decided — do not reopen** as settled: reopening is the rework the checkpoint exists to
prevent. The one exception is a decision whose `assumes` premise has visibly changed — say so first,
naming the premise and what it is now, before acting on it.
