---
description: Write a resume checkpoint before stepping away, then advise compact/clear/leave-open
argument-hint: "[topic-slug]"
allowed-tools: Bash(bash:*), Bash(git:*), Read, Write, Edit
---

!`bash "$HOME/.claude/token-park-context.sh"`

The user is about to step away for more than the one-hour cache TTL. Do two things, in order.

**1. Pick the topic, then write the checkpoint.** A project holds one checkpoint *per topic*, not
one in total — parallel sessions and separate strands of work each keep their own, and the block
above lists what is already parked here.

The user typed: **$ARGUMENTS**

- **An argument was given.** That is the topic, and it overrides your own judgement about which
  strand this is. Match it case-insensitively against the slugs above as a substring. Exactly one
  match: overwrite that file, but **name the file and its age and get a yes first**. No match: a new
  checkpoint under that slug, written without asking. Several matches: list them and ask, never pick
  the newest.
- **No argument, and this session continues a topic in the list.** Overwrite that file, naming it
  and its age in your reply so a wrong guess is visible at once. The slug is the part of the
  filename between the project and `.md`.
- **No argument, new strand.** Pick a slug: kebab-case, two or three words, about the work and not
  about the day (`shader-rework`, `audio-pass`, `token-sessions`). Never a date, because the
  file's mtime is the date and a slug carrying one can never be overwritten by its own follow-up.
- **Never touch a file belonging to another topic.** Two sessions in one project used to collide on
  a single `<project>.md`, and the loser silently lost its checkpoint. An overwrite nobody asked for
  destroys the only record of where that work stood.

Then write `$HOME/.claude/checkpoints/<basename of cwd>.<topic>.md` with the state a *cold* session
needs to resume without re-reading the work. Measured re-derivation without one is ~34k tokens; the
target here is under 5k, which is what makes ending the session the cheap option rather than the
expensive one. Keep it under ~80 lines and use this shape:

```markdown
<!-- park: session=<the session id printed above> topic=<slug> -->
# Checkpoint — <project> — <YYYY-MM-DD HH:MM>

## Task in flight
<one paragraph: what is being built and why, not a history of the session>

## State
- <file:line> — what changed, and whether it is finished
- branch / HEAD, and whether the tree is dirty

## Verified vs assumed
- confirmed by <command or file:line>: ...
- assumed, not checked: ...

## Next step
<the single next action, concrete enough to start cold>

## Blocked / open
<only what needs the user's decision; omit if empty>
```

The `<!-- park: -->` line is load-bearing, not decoration: `token-sessions.sh` reads it to mark the
right window as parked in the session table, and without it the file can only be matched by mtime,
which stops working the moment two sessions in one project park near each other.

Write paths, commands and `file:line` refs, never prose summaries of code — a pointer costs a few
tokens to store and saves a full re-read. Do not re-read files to write this; everything needed is
already in the window. If it is not, say so rather than reading.

**2. Then advise, using the context figure printed above.** `/park` is invoked when a gap is
*certain*, so the full window rewrite is guaranteed, not probable. That makes the comparison simple:

- keeping the session open costs `context x 2` weighted, which **scales** with the window;
- `/park` + `/clear` costs `(floor + checkpoint) x 2` ≈ **~136k**, plus ~23k for the park itself —
  **~159k all-in**, and **fixed**: it does not matter how large the session got.

The curves cross at **~80k**. So above ~80k recommend `/park` then `/clear`, and say what it saves
(at 105k: ~211k against ~159k; at 230k: ~460k against ~159k). Below ~80k recommend leaving it open
and eating the one gap — a fresh session would sit near the ~63k floor anyway, and the park would
have cost more than it saved.

Whatever the size: parking and then **not** clearing is the one combination that always loses. It
pays for the checkpoint and still eats the full rewrite.

Do not use the general restart break-even (~157k parked / ~224k unparked) here. That number answers
a different question — whether to cut a session whose cache is still warm — and it is wrong for a
certain gap.

The one real exception is not about tokens: if something is mid-flight in a way the checkpoint
cannot hold — a half-applied edit, a decision that would get re-litigated — say so and recommend
leaving it open. Rework outranks tokens.

State the recommendation in one or two lines with the number behind it. Do not restate the
checkpoint you just wrote — the user can read the file.
