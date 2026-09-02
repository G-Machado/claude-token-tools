# Tutorial — a week with the tools

This walks from a fresh install to the point where you are retuning the thresholds against
your own data. It assumes [INSTALL.md](INSTALL.md) is done.

---

## Day 1 — let it watch

Do nothing different. Use Claude Code as you already do. The Stop hook is writing one row per
cycle to `~/.claude/token-history.csv`, and until there are ~20 rows every view here is
technically correct and practically useless.

The one thing to look at is the **status line**, which works from cycle one:

```
change  8.2k/10k  ctx 84k  cache 41m
```

Read it right to left, because that is the order the numbers become urgent in:

- **`cache 41m`** — minutes of prompt-cache life left. Under 10, you have a decision to make.
  `cache COLD` means it has already lapsed and the next message you send pays a 2x rewrite of
  the whole window.
- **`ctx 84k`** — how big the window is. It only means something next to the cache number.
- **`8.2k/10k`** — output this cycle against the tier budget.

## Day 2 — read one cycle

After a session with some real work in it:

```sh
bash ~/.claude/token-cycles.sh
```

One row per prompt cycle: output, growth, context, and whether either budget was breached.

Two columns, two different failures:

- **output** over budget → the prompt bundled discovery, design and implementation into one
  message. The fix is splitting the prompt, not asking for less thinking.
- **growth** over budget → too much was read. This is the dearer mistake: growth is charged at
  the 2x cache-write rate and re-charged on every later cache miss.

Score a cycle against the tier it actually was:

```sh
bash ~/.claude/token-cycles.sh recon      # Q&A, one-file read, orientation
bash ~/.claude/token-cycles.sh change     # a scoped change or fix        (default)
bash ~/.claude/token-cycles.sh feature    # multi-file feature, plan, investigation
bash ~/.claude/token-cycles.sh 30000      # or a bare number
```

You will find your breaches cluster. Measured here, the **top 10% of cycles carried 34% of all
output** — budget overruns are not drift, they are single prompts that asked for three things.

## Day 3 — open the pane

```sh
bash ~/.claude/token-sessions.sh --watch
```

Leave it in a spare terminal. Every Claude Code session on the machine, the one about to lapse
at the top.

Per row: a **name** (derived from the session's own first prompt), the CLI's name beside it,
**context** size, **cost** so far split green/orange/blue (output / cache writes / cache reads),
a **growth** sparkline, an A–F **grade**, and **cache** minutes left.

The two glyphs at the start of a row:

- a moving bar = a turn is running right now; a hollow arrow = the most recently touched
  session; a diamond = there is a `/park` checkpoint on disk for it
- the **verdict**: a filled triangle = act now, a hollow one = a cut would pay if you want it,
  a dim ring = nothing to decide. Most rows are rings most of the time, which is the point.

Move with `j`/`k` or `1`-`9`, `d` to expand a row into the full panel, `?` for the key list.

**The reason this view exists:** 59% of measured gap rewrites had *another* of your own sessions
active during the idle window. The second terminal is what starves the first of its cache, and
each one also pays its own ~63k cold floor. Two sessions do not overlap work — they manufacture
gaps in each other.

## Day 4 — name the rows you keep coming back to

Derived names are fine for a session you will close in an hour. For the two or three you live
in, name them yourself. In the pane, select a row and type:

```
/n build-fix
```

`/` opens a prompt line; a line starting with `n` renames instead of filtering. The rest of the
line is the name — blanks inside it become dashes, so `/n unity scene merge` arrives as
`unity-scene-merge` and the column stays a column.

- `n` alone still re-rolls the derived name through variants built from the words the session
  actually used. If a typed name is set, `n` clears it and hands the row back to that pool.
- A bare `/n` also clears back to the derived name.
- To *filter* for the letter n, type `/ n` — the space is what says you meant to search.
- None of this touches `sessions/<pid>.json`. The CLI's name for a session is the CLI's
  business; a tool that reads state has no business writing into the state it reads.

Names live in `~/.claude/token-nicks.tsv` and survive restarts.

## Day 5 — the first gap warning

Sooner or later you will step away for lunch, come back, and type into a 180k session. The
`UserPromptSubmit` hook will say so.

It tells two cases apart, and they want opposite responses:

- **about to lapse** (inside the TTL) — nothing has been spent yet. Acting *now* is what saves
  the pass.
- **already lapsed** — the 2x rewrite is sunk; this message pays it either way. That makes this
  the **cheapest moment there will ever be to compact**: the full-price pass over the window is
  happening regardless, so compacting converts a sunk cost into a small window instead of paying
  it *and* keeping the big one.

The hook fires at 55 minutes but the TTL is 60, so a firing is not proof of an expiry. It says
which it was, and logs it to `token-gap-warn.log`.

## Day 6 — park before you leave

The failure above is best fixed *before* the gap, not after. When you are about to step away
from a session for more than an hour:

```
/park
```

It writes a resume checkpoint to `~/.claude/checkpoints/<project>.<topic>.md` — task in flight,
`file:line` state, verified vs assumed, next step — and then tells you what to do with the
window. One file per *topic*, not per project, so parallel strands each keep their own.

Then `/clear`, and next time:

```
/unpark
```

**The arithmetic, because it is the whole point.** Re-derivation after a clear measured
**34,066 tokens without a checkpoint** (n=29) and **~5k with one**. That drops the cost of
restarting from ~194k weighted to ~136k, and it is the one term in the break-even fully under
your control.

Two traps:

- **Parking and then not clearing is the one combination that always loses.** You pay for the
  checkpoint and still eat the full rewrite. `/park` does not save anything by itself — it
  lowers the price of clearing.
- **The rewrite is charged on the next request**, so clearing *before you type* skips it
  entirely. Never send a prompt into a COLD session you intend to clear.

List what is parked:

```sh
bash ~/.claude/token-sessions.sh --checkpoints        # this project
bash ~/.claude/token-sessions.sh --checkpoints all    # every project
```

## Day 7 — the decision table

You now have every input. The whole park/clear question is a lookup, not a judgement call:

| on returning | cache warm (`NNm`) | cache `COLD` |
|---|---|---|
| **you parked** | carry on; the ~23k park was insurance you did not need | above **~68k**: `/clear` *before typing*, resume from the checkpoint. Below it, carry on |
| **you didn't park** | carry on; nothing was lost | above **~97k**: `/clear` before typing and re-derive. Below it, carry on |

And one question asked *before* you leave: **is parking worth it at all?** Park+clear costs a
fixed ~159k all-in; carrying one gap costs `context x 2` and scales. They cross at **~80k**.
Below that, eating the gap is cheaper than parking.

Three thresholds, three different questions. Do not collapse them.

All three exist because of the **cold floor**: a fresh session starts at ~63k before you have
said anything (system prompt, tool schemas, skill listings, instruction file, memory). **You
cannot clear your way below the floor.** With a window smaller than a fresh start, clearing
makes it bigger.

## Week 2 — retune against your own data

```sh
bash ~/.claude/token-cycles.sh --stats
```

The floor, the break-even table, how often the hook actually fires and what set it off — all
rescored from `token-history.csv`. Because the history stores measured quantities and never a
bucket or a verdict, changing a threshold never invalidates a single row already on disk.

```sh
bash ~/.claude/token-sessions.sh --analytics
```

Where the spend went, median and p90 per cycle, a 14-day sparkline, breach and gap-rewrite
rates, and 7d-versus-before with arrows. `w` switches to weekly buckets, `[` and `]` page.

The line to watch across weeks is **OVERALL 7d** under the summary box: spend / production /
control, graded against your own median rather than against mine.

**Then change the numbers.** Every threshold shipped here was measured on one machine, one plan,
one kind of work. Override any of them from the environment:

```sh
export TOKEN_ALERT_BUDGET=15000    # output budget per cycle
export TOKEN_GROWTH_BUDGET=30000   # growth budget per cycle
export TOKEN_CACHE_TTL_MIN=60      # cache TTL, if yours differs
export TOKEN_PRICE_IN=5            # $/MTok input for your model
```

The full list is in [REFERENCE.md](REFERENCE.md); the derivations are in
[strategy-refactor.md](strategy-refactor.md) and [workflow-debt.md](workflow-debt.md).

## What not to bother trying

Automatic cache renewal. It looks like the obvious fix and it does not work: a `claude -p`
process shares exactly **~18,690 tokens** of system prompt with an interactive session, and
everything after that diverges and is rebuilt at 2x. A keep-alive ping therefore refreshes a
prefix your live session never sends, and *rebuilds* the window rather than reading it.

This was established at real cost — one uncontrolled ping at ~215k weighted, plus ~75k of
controlled probes. Do not re-derive it: [failsafe-findings.md](failsafe-findings.md).

What replaced it is a louder warning — the lapse bell and a desktop notification — because
acting early was always the cheaper move, and the pinger was trying to remove the need to act
and could not.
