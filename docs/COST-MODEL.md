# Token budget policy (CLAUDE.md extract)

These are the instruction-file sections the tools in this repo exist to enforce.
Copy the parts you want into your own `~/.claude/CLAUDE.md`. Every number here was
measured on one machine (Windows 11, Opus 5, a Unity project) — treat them as a
starting point and re-derive your own with `token-cycles.sh --stats`.

## Cost model

When trading off, treat these as expensive in this order:

1. **Rework** — work thrown away because an assumption turned out wrong.
2. **Tokens.**
3. **The user's real-world effort** — a playtest, a headset session, a build, a manual test run.

The user is the developer; doing the work is the job. Their time is the *cheapest* way to buy
certainty — a 30-second Editor focus beats 15k tokens of inference about whether something
compiles. Ask for the check, the playtest, the headset session, or the clarifying question
rather than spending tokens to avoid asking.

Never trade a token saving for rework. That ordering is unchanged.

## Verification is cheap — and asking is the cheapest kind

Verification never counts against a token budget, but prefer the cheapest *accurate* check.
A real-world confirmation usually beats a token-heavy inference: ask the user to focus the
Editor, run the scene, or confirm the assumption directly.

Before anything hard to reverse (commit, push, delete, overwrite), verify first — by whichever
route is faster.

**Verification vs clarification — different rules.** Ask for *verification* freely and
immediately; it is a few seconds of the user's time and it ends an assumption. **Batch
*clarifying* questions**: when the answer only changes work you have not started, keep going on
everything that does not depend on it and raise the open questions together at the next natural
stopping point. One list of three beats three interruptions.

## Token budget

A **prompt cycle** is one user message plus every tool call and follow-up until control returns
to the user. **Output** (thinking + text + tool arguments) is the signal for how much work a
cycle actually did — budget that, never total tokens.

Budget by task class, not one flat number:

| class | output | growth | typical |
|---|---|---|---|
| `recon` | ~5k | ~8k | Q&A, one-file read, orientation |
| `change` | ~10k | ~15k | a scoped change or fix |
| `feature` | ~20k | ~25k | multi-file feature, plan, investigation |
| `scene` | ~20k | ~60k | Unity scene merge / conflict resolution |

`scene` is provisional — guessed at n=0, not derived from history like the other three. It is a
**tier, not an exemption for `*.unity`**: scene YAML is the lowest-density, highest-cost content in
the repo (`MainScene.unity` is ~23k lines, ~200k tokens to read whole), so a careless full read
during ordinary `change` work must still trip the normal ceiling. Opt in only when the cost is
genuinely unavoidable — a merge with interleaved conflict hunks. `git diff`, grep by `m_Name` or
fileID, and line-ranged reads come first; when they suffice, the cycle is not `scene`.

Two budgets, because they are two different failures. Over on **output** usually means the prompt
bundled discovery, design, and implementation together and wanted splitting. Over on **growth** —
new material pulled into the window — means too much was read, and that is usually the dearer
mistake: growth is charged at the cache-write rate and re-charged on every later cache miss. One
heavy skill load has cost more than an entire day of ordinary cycles. If a task genuinely needs more, stop at a clean point and continue next cycle
rather than reading further to finish in one shot. What counts as clean depends on the task: for
code, a working state (builds/runs), not necessarily committed; for research, a stated conclusion
— what was found and what's being looked at next, not a partial trace.

Most of a cycle's *total* is re-cached context, which scales with session length, not with what
was asked. Split it: **growth** (new material you pulled in — controllable, be selective) versus
**churn** (existing context rewritten on a cache miss — not controllable, only avoidable by
ending the session). `--stats` separates them; judge a cycle on growth against its budget, never on
the raw re-cache number.

Raw tokens are not one currency, so never add them together. Relative to an uncached input token:
cache read **0.1×**, input **1×**, cache write **2×** (1-hour TTL), output **5×** — a 50× spread
between the cheapest and dearest term. Measured across **354 cycles**: cache writes **49%**,
output **34%**, cache reads **17%**. (An earlier "~7% output" here came from one churn-dominated
session and was wrong by ~5×.) So output is the second-biggest line, not a rounding error — and
it is concentrated: the **top 10% of cycles carry 34% of all output**. Budget breaches are not
drift, they are single prompts that bundled three tasks; split those and the term collapses.

Measure, don't estimate — self-reported guesses drift badly. `/tokens` prints per-cycle output,
re-caching and context; a `Stop` hook warns on breaches and logs one raw row per cycle. Tooling,
mechanism, and thresholds: `~/.claude/token-cycles.sh`, failures in `token-alert-errors.log`.

### Never park a large session across a gap

The prompt cache lives **one hour**. Reading from it costs 0.1×; writing to it costs 2× — a
**20× swing on identical content**. When the cache expires, the entire window is rewritten at
the write rate.

So resuming a big session after a long gap is the *worst* of the three options — worse than
continuing and worse than restarting. Measured here: cycle 12 at 22:20, cycle 13 at 13:59 the
next day, a 15.5-hour gap that rewrote a ~300k window from scratch (~600k input-equivalents)
where a fresh session would have cost ~108k plus re-derivation. About 5x, for nothing.

**If stepping away for more than an hour from a session above ~200k, close it.** Write the
notes first; start clean next time. This is not the old "cut long sessions" rule — a long
session you are actively working is cheap, because the cache keeps hitting. The *gap* is what
costs, and it is the one term here fully under the user's control.

**If a gap already happened, compact immediately — that is the cheapest moment there is.** The
full-price pass over the window is happening on that request either way; compacting there converts
a sunk cost into a small window instead of paying it *and* keeping the big one. Measured over 347
cycles: gap-induced full rewrites were 9% of cycles but **26% of total weighted cost**, and they
repeat — a session parked once tends to get parked again (`e41a40fd` paid it three times in one
day). `~/.claude/token-gap-warn.sh` is a `UserPromptSubmit` hook that says so automatically, in
two tiers: at **60k** (about the cold floor) it reports the rewrite and pushes `/park` for next
time; at **130k** it adds the compact-now advice, which is where that advice is finally in its
own favour. The low tier exists because 7 of the 15 gap rewrites after install sat *below* 130k,
at cycle 2-3 of young sessions — the penalty barely scales with session age, since the floor is
most of the rewrite. Every firing appends a row to `token-gap-warn.log`.

**Better still, decide at park time, not at resume time.** `/park` writes a resume checkpoint to
`~/.claude/checkpoints/<project>.<topic>.md` — task in flight, `file:line` state, verified vs
assumed, next step. One file **per topic**, not per project: parallel sessions and separate strands
each keep their own, and each file carries a `<!-- park: session=... -->` stamp so the watcher can
mark the right window. `token-sessions.sh --checkpoints [proj|all]` lists what is parked, newest
first — that is the index to point a fresh session at after a `/clear`. That is the one term in the break-even fully under your control: re-derivation measured
**34,066** without a checkpoint (n=29), ~5k with one, which drops restart cost from ~194k weighted to
~136k. When a gap is **certain** — which is exactly when `/park` runs — the comparison is not the
general restart break-even (~224k, which assumes the cache stays warm). Keeping the session open
costs `context x 2` and scales; `/park` + `/clear` costs `(floor + checkpoint) x 2` ~= 136k and is
fixed. `/park` itself measured **~23k weighted** (two invocations: 2,604 and 3,349 output, ~0.4 of a
median cycle), so park+clear is ~159k all-in and they cross at **~80k**. Below that, eating a
full gap is cheaper than parking - leave the session open. So if you know you are leaving for over an
hour: `/park` then `/clear`, essentially always. At 105k that is ~211k against ~136k; at 230k,
~460k against ~136k. The exception is not a token one — if something is mid-flight that the
checkpoint cannot hold, leave it open, because rework outranks tokens. The statusline shows `/park` once
context passes 120k, or as soon as `cache` drops under 10m on a window above 80k.

**Read the cache clock, don't guess at it.** The status line prints `cache NNm` — minutes of
prompt-cache life left, measured from the last cycle — and `cache COLD` once it has lapsed. That
is the whole park/clear decision made visible, so the four cases are a lookup, not a judgement
call:

| on returning | cache warm (`NNm`) | cache `COLD` |
|---|---|---|
| **you parked** | carry on; the ~23k park was insurance you did not need | above **~68k**: `/clear` **before typing**, resume from the checkpoint (~136k, against `context x 2` to carry). Below it, carry on |
| **you didn't park** | carry on; nothing was lost | above **~97k**: `/clear` before typing and re-derive (~34k, so ~194k all-in). Below it, carry on |

Three thresholds, three different questions — do not collapse them. **~80k** is asked *before*
you leave: is parking worth it at all (park+clear ~159k vs carrying one gap at `context x 2`).
**~68k** and **~97k** are asked *after* a gap, when the park cost is already sunk and the only
question left is clear-vs-carry: `(63k floor + re-derivation) x 2` against `context x 2`, and
re-derivation is ~5k with a checkpoint or ~34k without.

All three exist because of the floor, and none of them can go lower than it: **you cannot clear
your way below ~63k.** With a window smaller than a fresh start, clearing makes it bigger.

Two things make this work. First, the rewrite is charged on the next *request*, so clearing
before you type skips it entirely — never send a prompt into a COLD session you intend to clear.
Second, `/park` alone saves nothing: it only lowers the price of clearing, from ~34k of
re-derivation to ~5k. **Parking and then not clearing is the one combination that always loses**
— you pay for the checkpoint and still eat the full rewrite.

### Resuming is not restoring

Nothing you can type restores a lapsed cache. `/resume`, `-c` and `-r` only re-send bytes and
hope the prefix still hashes to something the server still holds; when it does not, you have
bought a full 2x rewrite. So price the three things called "resuming" separately — they are not
one action:

| | what happens | cost on the next message |
|---|---|---|
| keep typing in the open session | nothing rehydrated; the window already *is* the prefix | 0.1x, inside the TTL |
| `/resume` mid-session | loads a *different* transcript over the current one | 2x on the loaded window, essentially always |
| `claude -c` / `-r` | new process, transcript replayed from `.jsonl` | 0.1x if that session is warm, 2x if COLD |

**`/resume` mid-session is the worst of the three.** You pay a fresh write of whatever you load
*and* the session you left goes idle and starts its own lapse clock — the two-sessions failure
(59% of gap rewrites) executed inside a single terminal. If you are switching, `/clear` first,
then resume: same load, but nothing warm is stranded.

**Resuming is free until you speak.** The rewrite is charged on the next *request*, so loading a
transcript to look at it costs nothing — `/resume`, read, then `/clear` or quit bills exactly the
same as clearing blind. Use it that way: never clear a session you have not looked at, and never
type into one you meant to clear. `/resume` is a built-in rather than a skill, so it also carries
none of the load cost that makes `/update-config` and `/claude-api` expensive.

**Prefer `-r` to `-c`.** `-c` grabs the newest conversation in the cwd with no prompt, which is
how you reload a 250k window by reflex and eat ~500k before typing a word. `-r` makes the choice
explicit — though the picker shows you *which* session, not how big it is, so
`~/.claude/token-sessions.sh` is the thing to read first. `--fork-session` resumes into a new
session ID: cost-identical, but it stops the resumed run from appending to a transcript you may
still want intact.

**The prefix can break while the TTL is still good.** The system prompt carries the current date,
so crossing midnight invalidates from the first block down regardless of what `cache NNm` says.
This file and the memory index sit just as high, so editing either mid-session throws the whole
window away on the next message — batch `/remember` and CLAUDE.md edits to the end of a session,
or accept that you have just paid `context x 2`.

**Don't run more than two sessions at once.** 19 of 32 gap rewrites here (59%) had another of
your own sessions active during the idle window: the second terminal is what starves the first
of its cache, and each one also pays its own ~140k floor. Parallel sessions do not overlap work,
they manufacture gaps in each other.

**Watch them all at once.** `~/.claude/token-sessions.sh` lists every session on the machine —
context, idle minutes, and cache life — sorted with the one about to lapse at the top. Each row
is nicknamed from that session's first prompt (`analyse-cycle-budget`, `experiences-playing`)
with the CLI's derived-name suffix beside it, because the derived name alone says nothing about
the work. `--watch [secs]` redraws it in a spare terminal and takes keys live (`j`/`k` or `1`-`9`
select a session and open a panel with its opening and latest prompt, cycle stats and the
park/clear call for *that* window; `t` the analytics tab, `esc` back one step, `a` closed
sessions, `c` compact, `r` reload, `?` the key list, `q` quit);
`--browse` starts on that panel, `--analytics` on the history tab, `--compact` drops the prompt
line, `--all` includes closed
ones. A solid `▶` marks a session with a turn actually running — the Stop hook fires at the *end*
of a cycle, so a transcript newer than that session's last history row means the next one has
begun — a hollow `▷` merely the most recently touched, and `◇` a `/park` checkpoint on disk for
that window. Context colour **is** size, and only size — green under the parking bar, yellow past
it, orange and red at the two cut bars. It used to mix in cache state, which meant a row changed
colour without changing length; what the window costs *right now* is the cache column and the
advice line, because that is the pair that depends on the clock. The `cost` column is what the
session has spent so far in input-equivalents, split green output / orange cache writes / blue
cache reads — mostly-green is work, mostly-blue is rent. `OVERALL 7d` under the summary grades
spend / production / control across the last week against your own median, which is the line to
watch across weeks; `t` expands it into the whole history — where the spend went, median and p90
per cycle, a 14-day sparkline, breach and gap-rewrite rates, and 7d-versus-before with arrows.
Plan percentages need one calibration: run `/usage`, then set `TOKEN_PLAN_WEEK_USD` to match.
The desktop shortcut "Claude
Sessions" runs it in its own window — its flags live in
`~/.claude/token-sessions-launch.sh`, not in the `.lnk`. The status line
also appends ` | <id> <n>m` when *another* session is within 15 minutes of lapsing on a window
above 60k, which is the only moment the information is still worth acting on. Both read from
disk (`sessions/<pid>.json`, transcript records, `token-history.csv`) and cost no model tokens.

Two things that disk read gets wrong if written the obvious way, both fixed 2026-08-25 and both
worth knowing before touching that script again. **A transcript's mtime is not its last
activity**: resuming a session touches the file without adding a record, so a window the IDE
reopened at startup reports a full hour of cache life it does not have — measured here at 319 and
877 minutes of phantom warmth. Read the last record's `timestamp` instead, and compare it against
`now` through `mktime` on *both* sides so the zone offset cancels. **A pid does not identify a
session**: Windows recycles pids and `sessions/<pid>.json` outlives its process, so opening a new
IDE project can hand a dead session's pid to something unrelated and light it up as live. Check
the command too — but run `ps` as `COLUMNS=1000 ps -W`, because `ps` truncates every line to the
terminal width and the Claude binary path is ~105 characters, so in a normal window the match
target is cut clean off and live sessions vanish from the list entirely.

Note the asymmetry this creates: **continuing costs no re-derivation at all.** Re-derivation is
what you pay for *cutting*, so it is never an argument against carrying on — only against cutting
too early.

### A fresh session is not free — price it before recommending one

A new session restarts at the **cold floor** (median **63k** measured: system prompt, tool schemas,
skill listings, this file, memory) and then re-derives what it needs to resume (~34k). Restarting
resets to about **97k**, not to zero.

Both sides must be priced, not counted. What carrying context costs is **cache reads** (0.1×, once
per request); what a restart costs is a fresh **cache write** of the floor (2×) plus re-derivation:

```
carry / cycle  =  (context − floor − rederive) × requests_per_cycle × 0.1
restart        =  (floor + rederive) × 2

restart is worth it when   N_remaining  >  restart / carry
```

At the measured floor and ~2.3 requests/cycle: 120k context → N > 36.9, so almost never. 200k →
N > 8.2. 300k → N > 4.2. At this repo's ~6.6 cycles/session the break-even context is ~224k — or
~157k when a `/park` checkpoint exists, because that cuts re-derivation from ~34k to ~5k. That is
why the bands sit at **157k parked / 224k unparked**. The earlier 100k/140k came from adding raw tokens on
both sides and were 2–3× too low.

**Apply this whenever recommending a session cut, and state the numbers.** Never suggest "start a
fresh session" without checking that context is far enough above the floor for it to pay. Below
~97k a restart is strictly a loss. The two real levers are lowering the floor and lowering
re-derivation (better notes) — raising the bands does neither.

And note what the occupancy bands are *for*: re-reading the window is only ~13% of cost, so at
these sizes cutting a session is mainly a **quality** move — less attention dilution, lower
compaction risk, headroom against the hard window limit. Don't sell it as a saving.

`--stats` prints the floor and the break-even table. How this policy is actually performing, plus
its open debt, lives in `~/.claude/token-workflow-debt.md` — read it before retuning any threshold
or concluding that cutting sessions more often is the fix. Pointer here, bulk on demand.

## Heavy skills

Some skills cost more to load than the task is worth. `/update-config` was measured at 22% of a
day's usage for one invocation — it dumps the full settings schema. It is now
`user-invocable-only`: read `~/.claude/settings-reference.md` instead, and only ask the user to
run `/update-config` if the reference doesn't cover the case. Same shape as the memory index:
one pointer always loaded, the bulk fetched on demand.

`/claude-api` is the same problem, worse: **measured at 235,000 tokens for one invocation**
(2026-08-08) — 5× the entire cold floor, and it compounded to 822k of cache writes as the
enlarged window was rewritten. For prices, cache multipliers, cache minimums, invalidation
rules, and reading `usage`, read `~/.claude/pricing-reference.md` — an authoritative local
extract, ~600 tokens. Answering from it is *not* answering from memory, so the skill's
"never answer from memory" trigger is satisfied. Escalate to the full skill only for SDK
syntax, model migration, Managed Agents, or platform availability.

**Before any load expected to exceed the cycle's growth budget** — a heavy skill, a full read
of a large generated file, a big command dump — say what it will cost and why the cheaper path
won't do. Growth is charged at 2× and re-charged on every cache miss; it is the most expensive
thing a cycle can do.

## Reading files

Anything over ~500 lines: `Grep` or line-ranged `Read` only. Full-`Read` only files you intend
to rewrite. Usual hazards: `*.unity`, `*.asset`, `*.csproj`, `Library/**`, `node_modules/**`,
lockfiles, generated caches. This list is examples, not the rule — the rule is the size.

Read on a ladder, cheapest rung first, and stop at the rung that answers the question:
`grep -c` / `ls` / `git diff --stat` → `grep -n` with context → `sed -n 'X,Yp'` → full read.
A full read is for files you are about to rewrite. Skipping a rung is allowed but must be said
out loud first — which rung, roughly what it costs, and why the cheaper one won't do — then
proceed without waiting for an answer. Growth is charged at 2× and re-charged on every cache
miss, so the announcement exists to make the expensive moment visible before it happens, not
after it shows up in the hook.

