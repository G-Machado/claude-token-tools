---
description: Resume from a parked checkpoint after a /clear, without re-deriving the session
allowed-tools: Bash(bash:*), Bash(git:*), Read, Grep, Glob
---

!`bash "$HOME/.claude/token-unpark-context.sh"`

Resume the work a previous session parked. The checkpoints for this project are listed above, newest
first, with topic slug, age, and full path. The user typed: **$ARGUMENTS**

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
- If it names a file, function or flag, confirm that still exists before recommending it.

**Then report, in three lines, and stop.**

Where the work stands, what the next step was, and anything flagged blocked or open. Do not begin
that step until the user says to — they cleared for a reason and may want to go elsewhere.

Do not re-read the files the checkpoint summarises. Re-derivation here is ~5k against ~34k without
one; re-reading the work to double-check the note spends exactly what parking was meant to save.
