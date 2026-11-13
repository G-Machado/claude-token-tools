# Cost-effective Claude Code workflow — what this project has measured

A working routine distilled from `COST-MODEL.md`, `workflow-debt.md`, `failsafe-findings.md` and
the project memory. Rules first, numbers in the last section with their dates. Re-run
`~/.claude/token-cycles.sh --stats` before quoting any figure more than two weeks old.

Seven parts: the bill, starting, prompting, reading, working, leaving, parallel sessions — then
what not to try and the numbers.

## 1. What the bill is made of

Price per token relative to an uncached input token: **cache read 0.05×** (Opus 5.5; 0.1× older
models), **input 1×**, **cache write 2×** (1-hour TTL), **output 5×**.

Re-measured 2026-11-12 over 3,506 cycles: re-cache **38%**, cache reads **33%**, output **28%**.
Each cycle reads the full window ~**5.1** times, so **window size is the biggest single line on
the bill**, and a cache miss costs **40×** a hit.

Three costs can be controlled:

- **Growth**: new material pulled into the window. Reading less keeps it down.
- **Churn**: the whole window rewritten after the cache lapses. Avoiding gaps keeps it down. It
  was 45% of re-cache spend.
- **Output**: thinking + text + tool arguments, at 5×. Splitting bundled prompts keeps it down.

Priority when these trade against each other (user, 2026-11-11): **tokens › correctness of
claims › content › hand-off-ability › rework › user attention › time**. Irreversible actions
(commit, push, delete, overwrite, account swap) are verified first, always. They are never
traded away.

## 2. Starting a session

1. **Check what is already open.** Run `~/.claude/token-sessions.sh` or look at the widget. Each
   extra session pays its own floor and lets the others' caches go cold. Run **at most three at
   once**. In the early data, 59% of gap rewrites had a second session of the user's own active
   during the idle window.
2. **Resume from a checkpoint, not a transcript.** If the topic was parked, use
   `/unpark <topic>`. `--checkpoints` lists them.
3. **Never type into a COLD session you mean to clear.** The rewrite is charged on the next
   request, so `/clear` first. Looking at a resumed transcript is free until you send a message.
4. **Prefer `claude -r` to `-c`.** `-c` silently reloads the newest window in the folder, which
   can be 250k. `/resume` in the middle of a session is the worst option: `/clear` first, then
   resume.
5. **Pick the model once.** Switching model starts a fresh cache: a 127k window was rewritten
   in full. Switching effort level does **not** break the cache (measured, cw ≈ 100–400).

## 3. Shaping a prompt

A **prompt cycle** is one user message plus every tool call until control comes back. Budget
**output** and **growth** per cycle, by class:

| class | output | growth | for |
|---|---|---|---|
| `recon` | ~10k | ~15k | Q&A, orientation, one-file read |
| `change` | ~20k | ~30k | a scoped fix |
| `feature` | ~40k | ~50k | multi-file feature, plan, investigation |

- **One arc per prompt.** The top 10% of cycles carry 34% of output, and breaches come from
  single prompts that bundle investigation, design and implementation. If the build rests on
  something unverified, investigate first and stop. Use plan mode for this, so that approving
  the plan is the stop.
- **Don't stop between steps you asked for in the same prompt.** Budgets were doubled on
  2026-10-26 because extra stops cost more than they saved.
- **Ask for the 30-second check.** An Editor focus, a playtest or a "does it compile?" from the
  user costs less than ~15k tokens of inference. Ask for verification right away. Batch
  clarifying questions for the next natural stop.
- **Label claims.** Write "confirmed by `<cmd>` / `file:line`" or "assuming X". An unverified
  claim that gets promoted to a finding is rework later.

## 4. Reading

Use the cheapest rung that answers the question:

1. `grep -c`, `ls`, `git diff --stat`
2. `grep -n` with a few lines of context
3. Line-ranged `Read`
4. Full `Read`, only for files under ~500 lines or files you will rewrite

- **Size is the hazard, not file type.** `*.unity`, `*.asset`, lockfiles and `node_modules` are
  just the usual offenders. `token-readguard.js` refuses a whole-file read over 500 lines once, whether by Read or a bare `cat` in Bash.
  Retrying the same read is the announcement.
- **Before any load bigger than the cycle's growth budget, say what it costs** and why the
  cheaper path won't do. Heavy skills are the classic case: one `/claude-api` call cost 235k, and
  one `/update-config` call cost 22% of a day. Read `pricing-reference.md` or
  `settings-reference.md` instead.
- **For Unity questions, use the `unity` CLI before the YAML.**
- **Fetch MCP tool schemas only when needed.** Connecting costs ~11 tokens per tool name. Using a
  tool pays for its schema once per session at 2×.

## 5. While working

- **A long session that is actively used is cheap.** The cache keeps hitting (97.2% hit rate,
  median per session). The *gap* is what costs money, not the length.
- **Batch CLAUDE.md and memory edits at the end of the session.** Both sit high in the prompt
  prefix, so editing either mid-session rewrites the whole window on the next message. Crossing
  midnight does the same, because the date is in the system prompt.
- **Delegate only noisy, bounded work, and use a fork for it.** A fork inherits the parent's
  cache, so a test run, a build log or a wide grep stays in the fork's window and only its
  summary comes back. A cold subagent is a second session: it pays the floor and re-derives your
  context. Use one only for self-contained searches whose output is a list of paths.
- **Persist a fact in the cycle it was learned.** If a non-obvious fact cost tokens to establish,
  write it into the project `CLAUDE.md` or memory before moving on. Re-deriving it next session
  costs it again.

## 6. Stepping away and changing topic

The cache lives **one hour**. After that, the next message rewrites the whole window at 2×.

**Before leaving for more than an hour, with context above ~80k:** run `/park`, then `/clear`.
`/park` costs ~23k weighted. Below ~80k, absorbing the gap is cheaper than parking.
**Parking without clearing always loses:** you pay for the checkpoint and still pay for the
rewrite.

**When you come back:**

| | cache warm | cache `COLD` |
|---|---|---|
| parked | carry on | above ~97k: `/clear` **before typing**, then `/unpark` (re-orientation costs ~34k with a checkpoint too) |
| not parked | carry on | above ~97k: `/clear` before typing and re-derive |

- **If a gap already happened on a big window, compact right away.** The full-price pass happens
  on that request either way.
- **New topic with context ≥ ~81k:** `/handoff <topic>` parks the session, opens a fresh window
  on `/unpark`, and makes the old window read-only.
- **Same topic past ~150k:** let it lapse and unpark it rather than renewing it. That is a
  quality bar as much as a cost one.
- **300k is a hard stop.** `token-block.sh` refuses everything except park, compact, clear and
  exit.
- **A restart is not free.** It resets to the cold floor (~64–72k) plus re-derivation, not to
  zero. Below ~97k, a restart is a strict loss. Never recommend one without stating the numbers.

## 7. Parallel work (master and lanes)

- The master integrates from each lane's `## Summary` table and **never reads raw lane output**.
- Targets: master window **≤ 100k** at every integration point, delegate **≤ 150k**, **zero gap
  rewrites**, and the lowest **$ per confirmed finding**.
- The post-mortem that set these: session `9bde5243` cost $12.8, with a 373k-weighted gap
  rewrite, six concurrent delegates and two renewals past 226k.

## What not to bother trying

- **Keep-alive pings.** A `claude -p` ping shares only ~18.7k tokens of prefix with an
  interactive session, so it rebuilds a prefix your session never sends. One uncontrolled ping
  cost ~215k weighted. The fix that replaced it is a louder warning (`failsafe-findings.md`).
- **Cutting sessions more often to save money.** Re-reading the window above the restart floor
  is a small share of the bill. Cutting is mostly a quality move: less attention dilution and
  lower compaction risk.
- **Higher effort by default.** Cycles at xhigh average more requests than cycles at
  medium/high (9.0 vs 6.6), and every extra request re-reads the window. Task mix confounds this,
  so the real effect is somewhere between ~4% and ~36% per cycle. A controlled trial is pending.
- **Relying on compaction as a strategy.** n=2; its re-orientation cost is unmeasured. Park
  before compacting anything with decisions worth keeping, because compaction drops rules.

## The numbers, with dates

| figure | value | source / date |
|---|---|---|
| cold floor (context at cycle 1) | median 63.7k (CLAUDE.md uses ~72k) | `--stats`, 2026-11-12, n=139 |
| re-derivation after `/unpark` | 7.3k for the unpark cycle; **33.6k growth + 14.5k output to the first edit** | `--stats` 2026-11-12; memory 2026-10-04 |
| restart break-even context | ~158k (at 6.4 cycles/session) | `--stats`, 2026-11-12 |
| cut bar | ~235k | CLAUDE.md |
| `/park` cost | ~23k weighted | COST-MODEL.md, n=2 |
| cache hit rate | 97.2% (p10 93.7%, p90 98.4%) | `--stats`, 2026-11-12 |
| one point of hit rate | 13.4% of the bill | `--stats`, 2026-11-12 |
| output per cycle | median 3.5k, p90 23.5k | `--stats`, 2026-11-12 |
| auto-handoff net saving | ≈1.4% of spend at 0.05× reads | memory, sweep3, 2026-10-04 |

**Open caveat:** the ~158k break-even counts only the unpark cycle (7.3k) as re-derivation.
Measured to the first edit, re-orientation is ~33.6k of growth. With that figure the break-even
rises toward the ~235k cut bar. Treat the 150k renewal bar as a quality call, not a proven
saving.
