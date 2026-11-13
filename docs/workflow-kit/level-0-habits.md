# Level 0 — habits (no install)

In priority order. The first three are most of the saving.

## P1 — must

1. **Don't leave a big session idle for more than an hour and then keep typing in it.** The
   cache expires after 1h, and the next message rewrites the whole window at 2×. Measured: gap
   rewrites were **9% of prompts but 26% of total cost**.
   - Leaving for over an hour with a big window (roughly >80k context)? Ask Claude for a short
     resume note (task, `file:line` state, what is verified, next step), save it, then `/clear`.
   - Came back and didn't do that? **`/clear` before typing anything**, then paste the note.
     The rewrite is charged on the next message, so clearing first skips it.
2. **One arc per prompt.** Don't ask for "investigate X, design a fix and implement it" in one
   message when the fix depends on what the investigation finds. Ask for the investigation,
   read the report, then ask for the change. Plan mode does this for you: approving the plan is
   the stop. The worst 10% of prompts carry a third of all output, and they are bundled asks.
3. **Don't switch models mid-session.** Pick Opus or Fable when you open the session. Switching
   rewrites the cache. Changing effort is free.

## P2 — should

4. **At most three sessions at once.** Each one pays its own startup cost (~64k), and while you
   work in one, the others go cold. 59% of gap rewrites happened while another session was
   active.
5. **Read files cheaply.** Ask Claude to `grep` first and read line ranges. A full read of a big
   file (a lockfile, a generated asset, a 3,000-line source file) stays in the window for the
   rest of the session and is re-read on every request.
6. **Answer quick checks yourself.** "Does it compile?" or "what does the UI show?" takes you 30
   seconds and saves ~15k tokens of the model reasoning about it.
7. **Don't `claude -c` by reflex.** It silently reloads the newest conversation in that folder,
   possibly a 250k window. Use `claude -r` and pick the one you mean. Never `/resume` in the
   middle of a session: `/clear` first, then resume.

## P3 — nice to have

8. **Edit `CLAUDE.md` and memory at the end of a session.** They sit near the top of the prompt,
   so editing either mid-session rewrites the whole window on the next message. Working across
   midnight does the same, because the date is in the system prompt.
9. **New topic, big window (>~80k)?** Start a fresh session with a resume note rather than
   dragging the old context along.
10. **Avoid heavy built-in skills you don't need.** Some load hundreds of thousands of tokens of
    reference text: `/claude-api` measured 235k for one call.

## Things that don't work

- **Keep-alive pings** to hold the cache open. A separate `claude -p` process shares only ~19k
  tokens of prefix with your session, so it rebuilds rather than refreshes.
- **Restarting often "to save money".** A fresh session restarts at ~64k, not zero, and has to
  re-learn context. Below ~100k a restart is a strict loss. Restarting long sessions helps
  quality (less dilution) more than cost.
