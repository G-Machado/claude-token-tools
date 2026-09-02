# Token budgeting system — briefing for cross-reference

> **Note for readers of this repo.** This document was written to be handed to *another AI
> agent* for cross-checking, not as user documentation — that is why it addresses "the
> receiving agent" and asks for a reply. It is included because it is the fullest single
> account of how the system works and what is known to be wrong with it. For using the tools,
> start at [../README.md](../README.md); for the policy, [COST-MODEL.md](COST-MODEL.md).
>
> If you *are* an agent reading this on someone else's machine: the numbers below describe the
> machine it was written on. Compare, do not adopt.

**Purpose of this document.** It describes a token-budgeting workflow running on one
developer's Claude Code setup (Windows 11, Opus 5, a Unity project), including its
mechanism, its measured performance, and its known weaknesses. It is written to be handed
to another AI agent working on the same problem, so that agent can compare its own data
against these numbers and report back.

If you are the receiving agent, skip to **§9 What to send back** first — it tells you what
comparison is actually wanted — then read the rest.

Everything numeric here is a real measurement from this machine unless explicitly labelled
*assumed*. Snapshot taken 2026-08-08 at n=44 cycles / 9 sessions.

**If you read an earlier copy of this document, several core numbers have changed and the
model behind them was wrong.** The 2026-08-08 pass found that the whole system was counting
raw tokens as if they were one currency (see §2.4), which made the restart model off by
roughly an order of magnitude. The context bands moved 100k/140k → **200k/300k**, the cold
floor basis moved min → median (43,204 → 54,189), and growth gained a budget it did not have.
Anything you compared against the earlier version should be re-compared.

---

## 1. The problem this system exists to solve

Long agent sessions get expensive in a way that is invisible from inside them. Every request
re-reads the whole conversation window, so cost per cycle grows with session length rather
than with how hard the current question is. The naive reactions — "write shorter prompts",
"start a fresh session more often" — are both wrong in ways that only show up once you
measure. This system is an attempt to measure rather than guess.

Two framing rules sit above the whole thing:

**Cost model.** Three things are expensive, in this order:
1. **Rework** — work thrown away because an assumption turned out wrong.
2. **Tokens.**
3. **The user's real-world effort** — a playtest, a headset session, a build, a manual test run.

Note the ordering, which is deliberate and is the opposite of the obvious one. The user here
*is* the developer; doing the work is the job. Their time is therefore the **cheapest** way to
buy certainty — a 30-second Editor focus beats 15k tokens of inference about whether something
compiles. The rule that falls out: ask for the check, the playtest, the clarifying question,
rather than spending tokens to avoid asking. Never trade a token saving for rework.

An earlier version of this document listed real-world effort as the *most* expensive item.
That was a straight contradiction of the policy file it claims to describe, and it inverted
the resulting behaviour — it argues for burning tokens to avoid interrupting the user, when
the policy argues for interrupting the user to avoid burning tokens. If you are comparing
setups, this ordering is worth stating explicitly for yours: it depends entirely on whether
your user is the developer or a stakeholder whose attention is genuinely scarce.

**Verification is cheap — and asking is the cheapest kind.** Verification never counts against
a token budget, but the *cheapest accurate* check is preferred, and that is usually a
real-world confirmation rather than token-heavy inference. Before anything hard to reverse
(commit, push, delete, overwrite), verify first.

Verification and clarification have different rules. *Verification* is asked for freely and
immediately — it is seconds of the user's time and it ends an assumption. *Clarifying*
questions are **batched**: when the answer only changes work not yet started, keep going on
everything that does not depend on it and raise the open questions together at the next
natural stopping point. One list of three beats three interruptions.

---

## 2. The policy layer (what the agent is told)

### 2.1 Unit of account: the prompt cycle

A **prompt cycle** = one user message plus every tool call and follow-up until control
returns to the user.

The budgeted quantity is **output** — thinking + assistant text + tool-call arguments. Not
total tokens. Rationale: output is the only quantity that tracks how much work the cycle
actually did. Total is dominated by re-cached context, which scales with session length and
with what was asked in *previous* cycles.

### 2.2 Budget by task class, not one flat number

| class | output budget | growth budget | typical |
|---|---|---|---|
| `recon` | ~5k | ~8k | Q&A, one-file read, orientation |
| `change` | ~10k | ~15k | a scoped change or fix |
| `feature` | ~20k | ~25k | multi-file feature, plan, investigation |

**Two budgets, because they are two different failures.** Over on *output* means the prompt
bundled too much work. Over on *growth* — new material pulled into the window — means too much
was read, and that is usually the dearer mistake: growth is charged at the cache-write rate and
re-charged on every subsequent cache miss (§2.4). The growth column is new as of 2026-08-08 and
is derived, not chosen — see §5 for the fit and §7 for what is still weak about it.

Going over on output usually means the prompt bundled discovery, design and implementation
together and wanted splitting. If a task genuinely needs more, the instruction is to stop at a clean
point and continue next cycle rather than reading further to finish in one shot. "Clean"
is task-dependent: for code, a working state (builds/runs), not necessarily committed; for
research, a stated conclusion — what was found, what's next — not a partial trace.

### 2.3 Growth vs churn

Total per-cycle cost is split deliberately:

- **growth** — new material pulled into the window. You choose it. Being selective is the
  lever.
- **churn** — context already present being rewritten because the prompt cache missed. You
  cannot be selective about it; the only cure is ending the session.

A cycle is judged on *growth against its own budget*, never on raw re-cache. Judging on raw
re-cache confuses a careless read with an unlucky cache.

### 2.4 Tokens are not one currency — the correction that reframed everything

This section is new as of 2026-08-08 and is the single most important thing to cross-check,
because getting it wrong invalidates every threshold downstream of it.

The system originally counted **raw tokens** and added them together. They are not comparable.
Relative to one uncached input token:

| class | multiplier |
|---|---|
| cache read | **0.1×** |
| input (uncached) | 1× |
| cache write, 5-min TTL | 1.25× |
| cache write, 1-hour TTL | **2×** |
| output | **5×** |

These sessions run a 1-hour TTL, so writes are 2×. That is a **50× spread** between the
cheapest and dearest term, and any total that sums them is meaningless.

Measured on one session (`5ef7f3e5`), in cost-equivalents:

| | raw tokens | × mult | cost-equivalent | share |
|---|---:|---:|---:|---:|
| output | 29,456 | 5 | 147,280 | 7% |
| cache **write** | 822,445 | 2 | **1,644,890** | **80%** |
| cache read | 2,671,293 | 0.1 | 267,129 | 13% |

**80% of session cost is cache writes** — the thing that had no budget. Output, the only
budgeted quantity, is 7%. Cache reads, which the occupancy signal exists to reduce, are 13%.

**And it was one tool call.** At cycle 11 a documentation skill loaded to answer a question
about cache multipliers; context went 50,683 → 285,392 in a single cycle. Cost-equivalent
before that call: ~$1.19. After: ~$10.30. One skill invocation was **~87% of the entire
session**, and 8× the eleven cycles of conversation preceding it. Worse, 235k of growth
produced 822k of cumulative cache *writes*, because the enlarged window was then rewritten
~3.5× over the remaining cycles. **Growth is charged at 2×, then re-charged on every later
miss.** That compounding is why growth, not session length, is the lever.

Two rules came out of this directly:
- **The growth budget** in §2.2, and a fourth alert signal to enforce it.
- **A heavy-load pre-flight rule:** before any load expected to exceed the cycle's growth
  budget — a heavy skill, a full read of a large generated file, a big command dump — say what
  it will cost and why the cheaper path won't do. The specific offender was replaced with a
  ~600-token local extract (`pricing-reference.md`) covering the lookups actually needed.

Output discipline was *not* dropped. Output is still the dearest rate per token and still the
best proxy for how much work a cycle did. It is simply not the biggest bill.

### 2.5 Supporting rules that exist to lower cost

- **Reading files.** Anything over ~500 lines: grep or line-ranged read only. Full read only
  for files you intend to rewrite. (Hazards named: `*.unity`, `*.asset`, `*.csproj`,
  `Library/**`, `node_modules/**`, lockfiles, generated caches — examples, not the rule; the
  rule is size.)
- **Heavy skills.** Some skills cost more to load than the task is worth. One config skill
  was measured at **22% of a day's usage for a single invocation** because it dumps a full
  settings schema. It was demoted to `user-invocable-only` and replaced with a 3.7KB
  hand-written reference file. Same shape as the memory index: one pointer always loaded,
  the bulk fetched on demand.
- **Delegation.** No subagents for work depending on context already established in the
  session — the agent starts cold and re-derives it, which is the expensive path. Acceptable
  only for self-contained fan-out searches whose entire output is a list of paths or symbols.
- **Persisting what you learn.** When a non-obvious fact about the codebase/engine/tooling is
  established at token cost, write it to project `CLAUDE.md` or memory **in the same cycle**.
  Re-deriving it next session costs the same again. This is the only rule in the set that
  compounds.
- **Pointer-plus-bulk offloading.** Large design docs (37KB, 17KB, 13KB) sit behind one-line
  memory-index pointers. A cold session pays for the pointer, not the document.

---

## 3. The restart economics model — the central finding

This is the part most likely to be novel to another agent, and the part most worth
cross-checking.

**A fresh session is not free.** It restarts at the **cold floor** — system prompt, tool
schemas, skill listings, `CLAUDE.md`, memory index — and then re-derives whatever it needs to
resume the task. Restarting resets to floor + re-derivation, not to zero.

**The two sides are priced differently, and the first version of this model missed that.**
Carrying context is paid in **cache reads at 0.1×**, once per request per cycle. Restarting is
paid in a fresh **cache write at 2×** of the floor, plus re-derivation. Comparing them as raw
tokens compares a 90%-discounted stream against an amplified one-off, and overstated the case
for restarting by roughly an order of magnitude.

```
WRONG (original):
carrying on costs   (context - floor - rederive)                        per remaining cycle
restarting costs    (floor + rederive)                                  once

CORRECT (weighted):
carrying on costs   (context - floor - rederive) x reqs_per_cycle x 0.1  per remaining cycle
restarting costs    (floor + rederive) x 2                               once

restart is worth it when   N_remaining > restart / carry
```

At the measured **median** floor (54,189), assumed re-derivation (15,000) and assumed 2.3
requests per cycle:

| context | restart pays off after | reading |
|---|---|---|
| 60,000 | never | a fresh session would sit no lower |
| 120,000 | N > 11.8 | effectively never at 4.9 cycles/session |
| 200,000 | N > 4.6 | roughly a full session's work left |
| 300,000 | N > 2.6 | worth it with 3+ cycles left |

Consequences that changed the workflow:

- **The bands moved to 200k / 300k.** They track the weighted break-even (~192k at the measured
  4.9 cycles/session). The old 100k/140k tracked an unweighted one, were 2–3× too low, and were
  firing on 31% of cycles — well outside the 5–25% target band. If the floor moves, the bands
  move with it, but they are re-derived from the formula, never nudged by eye.
- **The floor basis is the median cold start, not the minimum.** Using the minimum made one
  unusually small cold start (32,567) the permanent basis of every break-even row: on
  2026-08-07 the 60k row read `N > 25.4` and the next day `N > 3.8`, a 6.7× swing with no
  change in behaviour. This is a one-line bug worth checking for in any comparable system.
- **Occupancy is mostly a QUALITY signal, not a cost one.** This is the uncomfortable
  consequence. Cache reads are ~13% of session cost, so "restart to save money" is usually
  false at these sizes. The genuine reasons to cut a session are **attention dilution,
  compaction risk, and headroom against the hard window limit** — and the alert now says that
  instead of implying a saving.
- **Better notes are a threshold lever, not a convenience.** Re-derivation is the only term
  controllable per-task, and it sits on the expensive (2×) side of the comparison.
- **Standing rule:** never recommend "start a fresh session" without checking that context is
  far enough above the floor for it to pay, and state the numbers when you do.

**Caveat, important:** `rederive` and `reqs_per_cycle` are both *stated parameters, not
measurements*. Nothing collected distinguishes "re-reading to catch up" from "reading something
new", and requests per cycle is not recorded at all — 2.3 comes from hand-counting one
session. `reqs` scales the carry side **linearly**, so it is now the weakest load-bearing
number in the model. See §7 debt items 2 and 3.

**A separate finding: never park a large session across a cache gap.** The prompt cache lives
one hour. Resuming a big session after a longer gap is worse than either continuing *or*
restarting, because the entire window is rewritten at the 2× write rate. Measured here: a
15.5-hour gap rewrote a ~300k window from scratch (~600k input-equivalents) where a fresh
session would have cost ~108k plus re-derivation — about 5× for nothing. The rule: if stepping
away for more than an hour from a session above ~200k, close it and write the notes first. A
long session being *actively worked* is cheap, because the cache keeps hitting. The gap is what
costs.

---

## 4. The mechanism layer

### 4.1 Collection

A single bash script, `~/.claude/token-cycles.sh` (~26KB, POSIX sh + awk), wired as a
**Stop hook** in `~/.claude/settings.json`:

```json
"hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "bash \"$HOME/.claude/token-cycles.sh\" --alert",
    "shell": "bash", "timeout": 10 } ] } ] }
```

It parses the session transcript JSONL, tallies per-cycle output / re-cache / occupancy,
appends one row to `~/.claude/token-history.csv`, and emits a warning if a threshold fired.

**Cost of collection: zero model tokens.** It runs in a hook that already fires. This is why
no subagent is involved — delegating would cost a full cold-context spawn to reproduce a free
bash script.

Session resolution order: `transcript_path` from the hook's stdin JSON payload (Windows paths
arrive JSON-escaped, backslashes normalised) → `CLAUDE_CODE_SESSION_ID` lookup → newest
transcript (non-hook modes only). Exact session matching is what keeps numbers correct when
several sessions are open at once.

### 4.2 Modes

| command | does |
|---|---|
| `--alert` | hook mode: append row, warn on breach |
| `--stats` | full report from the CSV; needs no session |
| `--retune` | sweeps candidate thresholds over the whole history; **changes nothing** |
| `--status` | one compact line for the status bar: context, growth, output, cycle |
| `/tokens [tier]` | slash command; per-cycle table for the current session, scored against `recon`/`change`/`feature` or a bare number |

### 4.3 Thresholds (env-overridable)

| var | default | meaning |
|---|---|---|
| `TOKEN_ALERT_BUDGET` | 20,000 | output ceiling used by the hook. The hook can't know task class, so it scores against the loosest tier — anything under is somebody's legitimate `feature` cycle, not a breach |
| `TOKEN_ALERT_GROWTH` | 25,000 | growth ceiling used by the hook; loosest tier, same reasoning |
| `TOKEN_GROWTH_BUDGET` | per tier | growth ceiling for the interactive table (8k/15k/25k) |
| `TOKEN_RESTART_THRESHOLD` | 60,000 | re-cache delta for one cycle |
| `TOKEN_CONTEXT_WARN` | **200,000** | occupancy band 1 (was 100,000) |
| `TOKEN_CONTEXT_HIGH` | **300,000** | occupancy band 2 (was 140,000) |
| `TOKEN_REDERIVE_COST` | 15,000 | assumed resume cost (see caveat) |
| `TOKEN_REQS_PER_CYCLE` | 2.3 | assumed requests per cycle; scales the carry side of the break-even linearly |
| `TOKEN_W_OUTPUT` / `_CACHE_WRITE` / `_CACHE_READ` | 5 / 2 / 0.1 | price weights vs an uncached input token; set `_CACHE_WRITE=1.25` for a 5-minute TTL |
| `TOKEN_RETUNE_AT` | 40 | rows before the retune prompt fires |
| `TOKEN_CONTINUATION_GAP` | 30 | minutes; a cycle-1 row within this of the previous row is treated as a resumed session, which is how re-derivation gets measured at all |

### 4.4 Four signals, deliberately separate

1. **output > 20k** — this cycle did too much work in one go.
2. **growth > 25k** — this cycle pulled too much new material into the window.
3. **re-cache > 60k** — this cycle rewrote a lot of cache at once.
4. **occupancy >= 200k / 300k** — the absolute window size, not a delta.

Signal 2 is the newest and closes the gap §2.4 exposed: the quantity driving ~80% of cost had
no ceiling at all. **Cycle 1 is exempt from it** — its "growth" is the cold load, which no
prompt chose, and scoring it would open every session on a breach. This exemption matters more
than it sounds: it is the difference between a signal that gets read and one that gets ignored.

Signal 4 exists because signal 3 misses the common failure: a session growing in small
increments never trips a delta threshold while every request re-reads a huge window.
Occupancy = `cache_read + cache_creation + input` on the last message of a cycle. It
**latches per session** (`token-occupancy.state`) and fires on a band *crossing*, so it does
not repeat every cycle once you are over.

Signal 3's message now **splits growth from churn and says which dominates**, because the same
re-cache number means two different mistakes and only one of them (churn) is an argument for
ending the session.

Band targets: judge each signal against **5–25%** fire rate; judge the **union** against
**~45–60%** with four signals live. Observed union here is 27% — *below* that expectation,
because the signals correlate: a heavy-growth cycle is usually also a high-re-cache cycle. A
union running under the naive independent-signals estimate is expected, not a fault.

### 4.5 CSV schema

```
ts,session,cycle,output,recache,context,fired
```
`fired` is a letter set: `o` output, `g` growth, `r` re-cache, `c` context, `-` none. Rows store
**raw measurements only**, never derived labels — which is the sole reason `--retune` can rescore
history against new candidate thresholds. (Generalised elsewhere as an instrumentation rule:
log raw quantities, bucket and classify at analysis time; a classifier baked into collection
is a bug you can't undo without re-running.)

**Growth is not a stored column** — it is reconstructed as the per-session context delta,
keyed on session id because sessions interleave in the file. That worked out well: the growth
signal was added months of rows later and could be scored against all existing history
immediately, which is the raw-storage rule paying for itself. **What the schema is missing is
`cache_read`**, and that is a real limitation: without it, `--stats` and `--retune` cannot
score history in cost-equivalents even though §2.4 says cost-equivalents are the only
meaningful unit. Only the per-session table, which re-reads the transcript, can weight
properly. See §7 debt item 5.

### 4.6 Failure-loudness

A hook that silently finds nothing looks identical to a hook that found no breach. Failure to
resolve a transcript is appended to `token-alert-errors.log` rather than exiting quietly.
That file has never been created — 0 failures to date.

---

## 5. Measured data (2026-08-08, n=44 across 9 sessions)

```
44 cycles, 2026-08-06 03:12 -> 2026-08-08 15:26
hook fired on 12 of 44 cycles (27% union)

rescored at current thresholds:
  output   > 20,000     4 cycles  ( 9%)
  growth   > 25,000     5 cycles  (14%  of 35 follow-on)
  re-cache > 60,000     5 cycles  (11%)
  context >= 200,000   10 cycles  (23%)

output per cycle: median 7,181  p90 18,683  max 26,690  mean 8,283
cycles per session: 4.9

re-cache split over 35 follow-on cycles:
  growth  median 8,149   total 593,755
  churn   median     0   total 656,668   (53% of re-cache)

cold floor (context at cycle 1, 7 sessions): min 32,567  median 54,189
re-derivation: assumed 15,000 | observed 10,637 - 63,495 across 4 resumed sessions
```

All four signals are inside the 5–25% per-signal band — the first time that has been true.

**How the growth budget was fitted.** Follow-on growth measures median 8,149, p80 17,846,
p90 21,443 (n=35). Candidate ceilings scored against the whole history: 12,000 → 31%,
15,000 → 31%, 20,000 → 26%, **25,000 → 14%**, 30,000 → 6%. 25,000 is the loosest candidate
landing inside the band, so it became the `feature` ceiling and the hook default. The
`recon` 8k / `change` 15k tiers are *not* independently fitted — they are the output tiers'
ratios applied to that anchor, and are the weakest part of the table (§7 item 6).

**Cold floor composition** (measured, at the 43k floor of the time): `CLAUDE.md` ~7.5KB ≈ 1.9k
tokens, memory index ~800B, one user skill ~370B. That is roughly **6% of the floor**. The other
~94% is system prompt, tool schemas and shipped skill listings — not reachable by any local
edit. Trimming `CLAUDE.md` by 2,261 bytes bought ~1.3% of the floor.

**The floor is not one number, and it is drifting up.** Observed cold starts now span
**32,567 – 79,830**, a 2.5× spread the median hides. The high end is this environment loading
MCP servers, extra agent types and deferred tool schemas — none of it chargeable to any prompt.
Every break-even row uses the single median, so a session that actually opened at 80k is priced
as if it opened at 54k. **Read the §3 table as ±40%.** If you are cross-referencing, report your
floor's spread and not just its centre; a single number here hid a real problem for two passes.

**Churn is concentrated, not spread.** Median 0, but it is now 53% of all re-cache (up from 19%
at n=33) — driven by long sessions crossing cache gaps. This is the empirical basis for not
judging cycles on raw re-cache: the same number means "you read carelessly" or "you were
unlucky", and only the first is actionable.

### Raw history, for independent rescoring

```csv
ts,session,cycle,output,recache,context,fired
2026-08-06 03:12,db1738e7,4,13160,19787,118632,c
2026-08-06 21:41,1703257c,2,7976,9961,97044,-
2026-08-07 00:42,1703257c,3,17762,101540,119700,rc
2026-08-07 10:31,57d16c26,1,11526,38025,56185,-
2026-08-07 12:03,57d16c26,2,13779,55871,74031,-
2026-08-07 12:05,57d16c26,3,7597,8910,82941,-
2026-08-07 14:40,112f3a09,1,2044,24569,42729,-
2026-08-07 14:54,112f3a09,2,23192,37337,80066,o
2026-08-07 15:03,b6695728,1,21518,59809,77969,o
2026-08-07 15:06,112f3a09,3,7900,8547,88613,-
2026-08-07 15:11,981184de,1,10475,25044,43204,-
2026-08-07 15:47,112f3a09,4,10663,22168,110780,c
2026-08-07 15:48,981184de,2,18683,25252,68456,-
2026-08-07 15:56,b6695728,2,17391,28789,106758,c
2026-08-07 15:56,981184de,3,1000,1829,70284,-
2026-08-07 16:45,112f3a09,5,3118,5810,116591,-
2026-08-07 16:52,981184de,4,22153,27064,97349,o
2026-08-07 17:18,112f3a09,6,2074,5007,121598,-
2026-08-07 17:29,e3635ef7,1,26690,77902,96062,or
2026-08-07 17:46,e3635ef7,2,8715,11910,107972,c
2026-08-07 18:02,e3635ef7,3,13494,21443,129415,-
2026-08-07 18:16,e3635ef7,4,357,2223,131638,-
2026-08-07 19:18,5ef7f3e5,1,1895,14407,32567,-
2026-08-07 19:28,5ef7f3e5,2,1788,2230,34797,-
2026-08-07 19:33,5ef7f3e5,3,1375,1554,36351,-
2026-08-07 19:36,5ef7f3e5,4,1583,1398,37749,-
2026-08-07 19:37,5ef7f3e5,5,1543,1633,39382,-
2026-08-07 19:43,5ef7f3e5,6,925,2391,41773,-
2026-08-07 19:46,5ef7f3e5,7,778,456,42229,-
2026-08-07 19:47,5ef7f3e5,8,1621,819,43048,-
2026-08-07 19:51,5ef7f3e5,9,3141,5375,48423,-
2026-08-07 19:55,5ef7f3e5,10,1351,2260,50683,-
2026-08-07 19:58,5ef7f3e5,11,3060,234709,285392,rc
2026-08-07 20:21,4c152096,1,12408,36029,54189,-
2026-08-07 20:23,4c152096,2,104,1214,55403,-
2026-08-07 22:20,5ef7f3e5,12,3618,272525,290685,r
2026-08-08 13:59,5ef7f3e5,13,12499,291657,309817,r
2026-08-08 14:09,5ef7f3e5,14,7181,8568,318385,-
2026-08-08 14:12,5ef7f3e5,15,5327,5682,324067,-
2026-08-08 14:21,5ef7f3e5,16,7855,9091,333158,-
2026-08-08 14:47,5ef7f3e5,17,14524,21019,354177,-
2026-08-08 14:49,5ef7f3e5,18,6375,7269,362326,-
2026-08-08 15:16,5ef7f3e5,19,4140,4622,366949,-
2026-08-08 15:26,5ef7f3e5,20,10110,11368,378317,-
2026-08-08 16:34,12cc28a4,1,38519,84151,102311,or
```

Two rows worth noticing: session `5ef7f3e5` is a long run of very cheap cycles (778–3,141
output) that never trips any signal until its final cycle explodes to 234,709 re-cache /
285,392 occupancy. And `e3635ef7` cycle 4 shows 357 output — cycles near zero output are
interruptions, not free work, and should be excluded from any average.

---

## 6. What is demonstrably working

- **Output discipline.** Median 7,181 sits comfortably inside the `change` tier; max 26,690
  overshoots the `feature` ceiling by 33% on a single cycle. No runaway cycles. The tier
  table appears calibrated about right. Note this held even while the *actual* bill was
  being driven by an unbudgeted quantity — a well-behaved metric is not evidence that you
  are measuring the right thing.
- **Raw-row storage paid for itself, concretely.** The growth signal was designed after 44
  rows had already been collected, and could be scored against all of them immediately
  because growth is derivable from the stored context column. Had the rows stored verdicts
  instead of measurements, the whole history would have been unusable for the retune.
- **Same-cycle note-writing.** Verifiable in file timestamps: two memory notes written inside
  the cycles that produced them; the next cycle cost 7,900 output because it read a note
  instead of re-deriving. Under the restart model this is also what keeps the restart
  threshold low.
- **Pointer-plus-bulk offloading.** Large docs behind one-line pointers; the cold session pays
  for the pointer only.
- **Zero-cost collection.** Hook-based, no model tokens, 0 recorded failures.
- **Raw-row storage enabling retroactive rescoring.** Every threshold question can be answered
  against all past data without re-running anything.

---

## 7. Downsides, open debt, and things known to be wrong

State these honestly to anyone cross-referencing; several are more interesting than the wins.

**1. The model was wrong for its first two passes, and looked healthy the whole time.** Every
threshold was scored on raw tokens (§2.4). Individual signals sat in band, the fire rate looked
sane, and the conclusion drawn from it — "cut sessions sooner" — was close to backwards. The
generalisable warning: a metric system that never contradicts itself may simply be measuring one
quantity consistently wrongly. What exposed it was pricing a single session end-to-end, which no
amount of threshold tuning would have surfaced.

**2. `rederive` — a term the restart model is highly sensitive to — is a guess.** Continuation
detection is live (cycle-1 row within 30 min of the previous row) and has found 4 resumed
sessions, spread **10,637 – 63,495**. The assumed 15,000 sits inside that range, which is
reassuring and proves nothing. The spread has *widened* as n grew, which is the opposite of
converging. Needs n≥5 to read, n≥10 to move the parameter.

**3. `TOKEN_REQS_PER_CYCLE` is now the weakest load-bearing number.** It scales the carry side
of the break-even **linearly**, and it is one hand-count from one session (30 deduped requests /
13 cycles = 2.3). Halve it and the bands should roughly double; double it and they should halve.
The collector already dedupes requests by message id, so counting them per cycle and storing the
count is a small change — it should happen before the next retune, because no other parameter
moves the bands this hard on this little evidence.

**4. The cold floor is mostly not ours to cut — and is not one number.** ~94% is system prompt,
tool schemas and shipped skill listings; total achievable local saving is ~1–2% of the floor, so
this is closed as *low ceiling*, not solved. Worse, observed floors span **32,567 – 79,830**
depending on what the environment loads (MCP servers, agent types, deferred tool schemas). Every
break-even row uses one median. Treat §3 as ±40%.

**5. The CSV cannot support cost-weighting across history.** It stores output, re-cache and
context, but not cache *reads* — so `--stats` and `--retune` still score raw quantities while
§2.4 insists cost-equivalents are the only meaningful unit. Only the per-session table, which
re-reads the transcript, weights properly. Adding a `read` column is the fix; old rows would
simply lack it, and the parsers already skip short rows.

**6. The growth budget is a first fit, not a calibration.** Only the `feature` ceiling (25k) was
fitted to the band; `recon` 8k and `change` 15k are the output tiers' ratios applied to that
anchor. Median follow-on growth is 8,149, so a genuine `recon` cycle sits exactly on its own
ceiling — that tier is likely to fire constantly and needs checking at the next n≥40 prompt.

**7. Collection has a tail-loss failure mode.** Rows are appended only in `--alert` mode, so
a session that ends without a Stop hook firing loses its last cycle. Some early sessions have
no rows at all (they predate the history file).

**8. The policy is self-reported unless measured.** An explicit rule exists — "measure, don't
estimate — self-reported guesses drift badly" — because a model's own sense of how much it
spent turned out unreliable. Any comparable system that relies on the agent estimating its own
usage should be treated as unvalidated.

**9. Overhead of the policy itself.** The policy text lives in an always-loaded `CLAUDE.md`
and costs ~1.9k tokens of every single session's floor. Design derivations were deliberately
moved out to a companion file (`token-workflow-debt.md`) so the always-loaded file carries
the rule and not the reasoning. This is a real, permanent, per-session tax paid to save on a
variable cost — worth verifying that it nets out.

**10. Snapshot drift — recurring, and now partly addressed.** At the last pass the companion
debt file's snapshot was from n=16 while §5 was at n=33, and figures had moved materially
(median output 10,663 → 7,597, churn share 39% → 19%, floor min 42,729 → 32,567, 60k break-even
N>25.4 → N>3.8). Both files are now refreshed together at n=44 and the debt file's review
procedure ends with "update the snapshot table; note what changed and why". But the drift keeps
happening: **this document itself was a full pass stale** — it still described three signals, the
unweighted formula, 100k/140k bands and "growth has no budget" after all four had changed. A
system that records measurements needs a *mechanical* refresh trigger, not a written intention;
that trigger does not exist yet, and this is the honest open item.

---

## 8. Design decisions taken deliberately (and why)

These are the choices most likely to differ between implementations, so they are the most
useful to compare.

- **Retune never auto-applies.** `--retune` prints what each candidate *would* have fired at
  and changes nothing. A threshold that moves on its own makes every earlier row mean
  something different, and the drift is invisible afterwards. The prompt at n=40 says "there
  is enough history now, go look" — a human applies the change.
- **The hook scores against the loosest tier (20k output / 25k growth), not the task's tier.**
  The hook cannot know task class. Scoring tighter would flag every legitimate `feature` cycle.
- **Cycle 1 is exempt from the growth signal.** Its growth *is* the cold load, which no prompt
  chose. Without the exemption every session opens on a breach and the signal stops being read.
  The same reasoning made the re-cache alert say "that is the cold load, not something this
  prompt chose" on cycle 1 rather than attributing it to growth.
- **Weights are parameters, not constants.** `TOKEN_W_*` default to the 1-hour-TTL prices but
  are overridable, because the write multiplier changes with TTL (2× vs 1.25×) and a system
  running 5-minute caching would draw different conclusions from identical raw data.
- **Churn deliberately gets no budget.** Growth is chosen and therefore budgetable; churn is
  the price of session length and no prompt can choose it. Budgeting it would produce an alert
  the agent cannot act on.
- **Occupancy latches per session and fires on band crossing**, not every cycle once over —
  otherwise the signal becomes noise the user learns to ignore.
- **Below n=5, the report prints a spread rather than a median.** With 2–3 samples a median is
  effectively just one of them, and this particular term swings the break-even hard enough
  that a falsely settled-looking number is worse than no number.
- **No subagent anywhere in the loop.** A free bash script beats a cold-context spawn.
- **Budget output, not total.** Total is dominated by factors the current cycle didn't cause.

---

## 9. What to send back

If you are an agent running a comparable token-accounting setup, the following is what makes
cross-referencing worth anything. Send raw numbers, not impressions.

**A. Your equivalents of the core measurements**
1. Cold floor: context occupied at cycle 1, min and median, and how many sessions that's over.
   Also its composition if you can break it down (system prompt vs tools vs user files).
2. Output per cycle: median, p90, max, mean, n. State explicitly whether "output" for you
   includes reasoning tokens and tool-call arguments — if it doesn't, our numbers are not
   comparable and you should say so rather than aligning them.
3. Cycles per session.
4. Re-cache split into growth vs churn if you can separate them; if you can't, say so — that
   itself is a useful data point about tooling.
5. Re-derivation on resume: measured if possible, with n and spread. **This is the highest-value
   number you can return.** It is the weakest term in our model and the only one a second
   dataset could meaningfully strengthen.

6. **Requests per cycle**, if you can count them — how many API round-trips one user turn
   costs you. This is our debt item 3 and it scales the restart model linearly. Second only to
   (5) in value.

**B. Threshold behaviour**
7. Your thresholds and their fire rates, per signal and union.
8. Whether any candidate threshold lands in a sensible band for you, or whether you see the
   "no middle" problem — where every candidate fires either far too often or never, which for
   us was a symptom of scoring the wrong quantity rather than of a small sample.

**C. Judgement questions — answer with reasoning, not just yes/no**
9. **Do you weight token classes by price, or count raw tokens?** If raw: re-derive your
   thresholds weighted and tell us how far they move. This single change moved our context
   bands 2–3× and inverted the "cut sessions sooner" conclusion. It is the highest-value thing
   in this document and the one most likely to be wrong in a comparable system.
10. Does the restart break-even in §3 hold on your data? At what context size does a fresh
    session stop being a loss for you?
11. Is budgeting *output* the right choice, or have you found a better proxy for "how much work
    did this cycle do"? Note our position: output stayed budgeted after we found it was only
    ~7% of cost, because it is still the best *work* signal — cost and work are different
    questions and we now think they need different metrics.
12. Do the tier sizes (output 5k/10k/20k, growth 8k/15k/25k) survive contact with your
    workload, or do they need to be workload-relative rather than absolute?
13. How do you keep documentation in step with a system whose numbers move? Our debt item 10 —
    every written record here has now been a full pass stale at least once, including this one.
14. Does the always-loaded policy tax (debt item 9) actually net out positive in your setup?
    A ~2k-token permanent floor cost to save on a variable cost is an unverified bet here.

**D. Anything we're missing**
15. Signals we don't collect that turned out to matter for you.
16. Failure modes of your collection you had to fix — ours are in §4.6 and debt item 7.

Return raw rows if you have them. Rows that store measurements rather than verdicts can be
rescored against our thresholds and ours against yours; rows that store verdicts cannot.

---

## 10. Source files (this machine)

| file | role |
|---|---|
| `~/.claude/CLAUDE.md` | the policy — always loaded, ~10KB |
| `~/.claude/token-workflow-debt.md` | performance log, design derivations, open debt — loaded on demand |
| `~/.claude/token-strategy-refactor.md` | the 2026-08-08 weighted-cost analysis; fully applied, kept for the derivation |
| `~/.claude/pricing-reference.md` | ~600-token local extract of the price/caching rules, so a multiplier lookup never loads the full docs skill |
| `~/.claude/token-cycles.sh` | the mechanism, ~32KB |
| `~/.claude/token-history.csv` | one raw row per cycle |
| `~/.claude/token-occupancy.state` | per-session latch for the occupancy band |
| `~/.claude/token-retune.state` | latch for the n≥40 retune prompt |
| `~/.claude/token-alert-errors.log` | hook failures (never created to date) |
| `~/.claude/commands/tokens.md` | the `/tokens` slash command |
| `~/.claude/settings.json` | Stop-hook wiring |
