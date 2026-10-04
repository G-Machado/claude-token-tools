---
description: Resume from a parked checkpoint after a /clear, without re-deriving the session
allowed-tools: Bash(bash:*), Bash(git:*), Read, Grep, Glob
---

!`bash "$HOME/.claude/token-unpark-context.sh"`

Resume the work a previous session parked. The checkpoints for this project are listed above, newest
first, with topic slug, age, and full path. The user typed: **$ARGUMENTS**

A trailing `--handoff` is not part of the topic: drop it before matching. It means `/handoff` opened
this window mid-flow; nobody cleared to go elsewhere.

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
- **`--handoff` with anything waiting on the user, or a check failed:** report in three lines and
  stop, with the waiting items as the `▶` block.

**Working from it.** Read the Map ranges only when a Next step needs them, as ranged reads; skip the
`not here:` places and use Facts instead of reading. An `open:` line comes with its check: run that
command rather than searching. Do not re-read the files the checkpoint summarises.

Treat **Decided — do not reopen** as settled: reopening is the rework the checkpoint exists to
prevent. The one exception is a decision whose `assumes` premise has visibly changed — say so first,
naming the premise and what it is now, before acting on it.
