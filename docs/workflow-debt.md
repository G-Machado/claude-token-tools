# Token workflow — performance log and open debt

Companion to the "Token budget" section of `CLAUDE.md`. That section is the *policy*;
this file records whether the policy works and what is known to be wrong with it.
Update it when you retune. Keep measurements, not impressions.

---

## Measurement snapshot

Taken 2026-08-24. Source: `token-cycles.sh --stats` over 348 cycles / 52 sessions
(2026-08-06 -> 2026-08-24). The 2026-08-08 snapshot is kept below for trend.

| quantity | 2026-08-08 (n=44) | 2026-08-24 (n=348) |
|---|---|---|
| output per cycle | median 7,181 / p90 18,683 | median 7,379 / p90 23,192 / mean 10,511 |
| cycles per session | 4.9 | 6.6 |
| **cold floor** | median 54,189 | **median 63,120** (min 32,567, n=45) |
| re-cache split | churn 53% | churn 63% |
| growth per follow-on cycle | median 8,149 | median 9,893 |
| **re-derivation** | assumed 15,000, n=4 | **measured median 34,066, n=29** |
| fire rate (union) | 27% | 33% |
| by signal | 9 / 14 / 11 / 23% | output 14 / growth 13 / re-cache 18 / context 23% |
| hook failures | 0 | 1 line in 18 days (gap-warn, no session_id, 2026-08-19) |

**Nothing needed retuning.** `--retune` marks all four current thresholds (20k output,
25k growth, 60k re-cache, 200k context) in band. The per-cycle budget is being met:
the median cycle spends 7.4k output against a 10k `change` ceiling and grows 9.9k
against 15k. The policy's *alerting* half is working as designed.

What is not working is everything the alerts cannot reach - see the fourth pass below.

## Measurement snapshot (2026-08-08, superseded)

Taken 2026-08-08. Source: `token-cycles.sh --stats`.

| quantity | value |
|---|---|
| recorded cycles | 44 across 9 sessions (2026-08-06 03:12 → 2026-08-08 15:26) |
| output per cycle | median 7,181 · p90 18,683 · max 26,690 · mean 8,283 |
| cycles per session | 4.9 |
| **cold floor** | **min 32,567 · median 54,189** (7 cold starts) |
| re-cache split | growth 593,755 · churn 656,668 (53%, median 0) |
| growth per follow-on cycle | median 8,149 · p80 17,846 · p90 21,443 (n=35) |
| re-derivation | assumed 15,000 · observed 10,637–63,495 (n=4) |
| fire rate (union) | 27% |
| fire rate by signal | output 9% · growth 14% · re-cache 11% · occupancy 23% |
| hook failures | 0 (`token-alert-errors.log` never created) |

n=44 is past the n≥40 retune gate, and the 2026-08-08 pass used it: the context bands and the
growth budget below are derived from this history, not chosen. The hook re-prompts per further 40.

Commands: `--stats` (report), `--retune` (threshold sweep, changes nothing), `--alert` (hook),
`--status` (status line), bare/tier (per-session table).
Knobs: `TOKEN_ALERT_BUDGET`, `TOKEN_ALERT_GROWTH`, `TOKEN_GROWTH_BUDGET`,
`TOKEN_RESTART_THRESHOLD`, `TOKEN_CONTEXT_WARN/HIGH`, `TOKEN_REDERIVE_COST`,
`TOKEN_REQS_PER_CYCLE`, `TOKEN_W_OUTPUT/CACHE_WRITE/CACHE_READ`, `TOKEN_RETUNE_AT`,
`TOKEN_CONTINUATION_GAP`.

All four signals sit inside the 5–25% per-signal band. The union runs *below* the ~45–60% four-signal
expectation because the signals correlate — a heavy-growth cycle is usually also a high-re-cache one.

### Coverage caveat

Four sessions in `token-occupancy.state` have no rows, and `db1738e7` starts at cycle 4 —
these predate the history file, not a collection bug. The `cycle > lastcycle` dedup guard is
intact. Rows are only appended in `alert` mode, so a session ending without a Stop hook
loses its tail.

---

## The restart economics model

The finding that reframed everything else, now in its corrected form. A fresh session is not
free — it lands back at the **cold floor** (median 54,189: system prompt, tool schemas, skill
listings, `CLAUDE.md`, memory) and then re-derives what it needs to resume
(`TOKEN_REDERIVE_COST`, assumed 15k). Restarting resets to ~69k, not to zero.

The first version of this model counted raw tokens on both sides and was wrong by roughly an
order of magnitude. The two sides are priced differently: carrying context is paid in **cache
reads at 0.1×**, once per request; a restart is paid in a fresh **cache write at 2×** of the
floor, plus re-derivation.

```
carrying on costs   (context - floor - rederive) x reqs_per_cycle x 0.1   per remaining cycle
restarting costs    (floor + rederive) x 2                                once

restart is worth it when   N_remaining > restart / carry
```

At the measured floor and `TOKEN_REQS_PER_CYCLE=2.3`:

| context | restart pays off after | reading |
|---|---|---|
| 60,000 | never | a fresh session sits no lower |
| 120,000 | N > 11.8 | effectively never at 4.9 cycles/session |
| 200,000 | N > 4.6 | roughly a full session's worth of work left |
| 300,000 | N > 2.6 | worth it with 3+ cycles left |

Consequences:

- **The bands moved to 200k/300k.** They track the weighted break-even (~192k at 4.9
  cycles/session). The old 100k/140k tracked an unweighted one and fired on 31% of cycles.
- **Occupancy is mostly a quality signal.** Cache reads are ~13% of session cost, so restarting
  to reduce them rarely clears the bar. The real reasons to cut are attention dilution,
  compaction risk, and the hard window limit — which is what the alert now says.
- **Better notes are still a threshold lever.** Re-derivation is the only term you control
  directly per-task, and it sits on the expensive (2×) side of the comparison.

`rederive` and `reqs` are both *stated parameters, not measurements*. Nothing in the CSV
distinguishes "re-reading to catch up" from "reading something new", and requests per cycle is
not recorded at all. Treat 15,000 and 2.3 as working assumptions — see Open debt.

---

## What is working

**Output discipline.** Median 11.5k sits in the `change` tier; the worst cycle overshot the
`feature` ceiling by 16%. No runaway cycles. The budget table is calibrated about right.

**Same-cycle note-writing.** Verifiable in timestamps: `type2-variant-direction.md` (15:02)
and `client-approval-before-implementation.md` (15:05) were written inside the cycles that
produced them; the next cycle cost 7,900 output because it read a note instead of re-deriving.
Under the model above this is also what keeps the restart threshold low.

**Pointer-plus-bulk offloading.** `MODULE_SYSTEM.md` (37KB), `THEME_VARIANT_PLAN.md` (13KB),
`INTERACTIVE_QUOTE_TOOL.md` (17KB) sit behind one-line memory pointers — same shape as
`settings-reference.md` behind the `/update-config` fix. A cold session pays for the pointer.

**Hook cost.** Collection runs inside a hook that already fires, at zero model-token cost.

---

## Resolved (third pass, 2026-08-08)

The pass that came out of `token-strategy-refactor.md` — a cost-weighted re-read of the record
after one `claude-api` skill load turned out to be ~87% of a session. All of C1–C7 are now applied.

- **Every number was counted in raw tokens** → weights added (`TOKEN_W_OUTPUT` 5,
  `TOKEN_W_CACHE_WRITE` 2, `TOKEN_W_CACHE_READ` 0.1). The per-session table prints a
  cost-weighted breakdown; the break-even model is weighted on both sides.
- **`read_floor()` returned the minimum, not the median** → one-line fix. The minimum made one
  unusually small cold start (32,567) the permanent basis of every break-even row; on 2026-08-07
  the 60k row read `N > 25.4` and the next day `N > 3.8`, a 6.7× swing with no change in
  behaviour.
- **Bands mistuned (old open debt 3)** → `TOKEN_CONTEXT_WARN` 100k → **200k**,
  `TOKEN_CONTEXT_HIGH` 140k → **300k**, derived from the weighted break-even at n=44. 100k was
  firing 31%; 200k fires 23%, inside the band. The sweep could not see why before because it was
  scoring the wrong quantity.
- **Growth had no ceiling (old open debt 4)** → growth budgets added
  (`recon` 8k / `change` 15k / `feature` 25k) with a fourth alert signal, fire code `g`, a
  scored column in the per-session table, and a `--retune` sweep of its own. 25,000 is the
  lowest candidate landing in the 5–25% band (14% of 35 follow-on cycles); 20,000 fires 26%,
  12–15,000 fires 31%. **Cycle 1 is exempt** — its "growth" is the cold load, which no prompt
  chose, and scoring it would open every session on a breach.
- **Heavy loads were treated as ordinary tool calls** → pre-flight rule in `CLAUDE.md`, plus
  `~/.claude/pricing-reference.md` (~600 tokens) so a multiplier lookup never loads the
  235k-token `claude-api` skill.
- **The occupancy alert oversold restarting as a saving** → reframed as a quality signal
  (attention dilution, compaction risk, headroom), with the weighted cost line printed beside it
  rather than instead of it.
- **The re-cache alert gave one number for two mistakes** → it now splits growth from churn in
  the message and says which one dominates, because only one of them is a reason to end the
  session.

## Resolved (second pass, 2026-08-07)

- **Re-cache had no budget concept** → `--stats` now splits every follow-on cycle into growth
  vs churn. See Design notes for what the split showed.
- **`rederive` was pure assumption** → continuation detection now measures it and prints the
  observation beside the assumption. Below n=5 it deliberately prints a *spread, not a median*,
  because with two samples a median is just the lower one — and this term swings the break-even
  hard enough that a falsely settled-looking number would be worse than no number.
- **No way to retune** → `--retune` sweeps five candidates per signal over the whole history,
  marks which land in the 5–25% band, and refuses to suggest anything at n<40.
- **Floor never attacked** → measured and trimmed; see Open debt 1 for why the ceiling is low.

## Resolved (first pass)

- **Cold floor untracked** → `--stats` now reports min/median cycle-1 context and the
  break-even table; the occupancy alert says what a restart actually buys instead of "cut a
  session". Standing rule added to `CLAUDE.md`.
- **5–25% band predated the third signal** → `--stats` now states the union band (~40–50%
  with three signals) separately from the per-signal band (5–25%). Every signal is inside its
  band today; only the union scoring was wrong.
- **No retune mechanism** → the hook prompts at `TOKEN_RETUNE_AT` (default 40) rows and
  latches, re-prompting each further 40. Verified: fires once, silent after.

The retune prompt deliberately **does not change thresholds automatically.** A threshold that
moves on its own makes every earlier row mean something different, and the drift is invisible
afterwards. It says "there is enough history now, go look" — you apply the change.

---

## Design notes

Moved here from `CLAUDE.md` so the always-loaded file carries the rule and not the derivation.

**Why re-cache is not one number.** `cache_creation_input_tokens` bundles two things with
different causes. *Growth* is new material pulled into the window — you choose it, and being
selective is the lever. *Churn* is context that was already there being rewritten because the
cache missed — you cannot be selective about it; the only cure is ending the session. Measured
across 35 follow-on cycles: growth totals 593,755, churn totals 656,668 (53% of re-cache), and
churn's median is **0** — it is concentrated in a few cycles, not spread. Judging a cycle on raw
re-cache confuses a careless read with an unlucky cache. Growth now has its own budget and its own
alert; churn deliberately does not, because no prompt can choose it.

**Why occupancy is tracked separately from the re-cache delta.** The 60k re-cache trigger catches
a cycle that dumps a lot at once, but a session growing in small increments never trips it while
every request re-reads a huge window. Occupancy (`cache_read + cache_creation + input` on the
last message of a cycle) is the absolute size, not a delta. It latches per session in
`token-occupancy.state` and fires on a band *crossing*, so it does not repeat every cycle once
you are over.

**Why no subagent checks any of this.** A hook already runs it every cycle at zero model-token
cost. Delegating would cost a full cold-context spawn to reproduce a free bash script.

**Why the retune never auto-applies.** A threshold that moves on its own makes every earlier row
mean something different, and the drift is invisible afterwards. `--retune` prints what each
candidate would have fired at and changes nothing.

---

## Open debt

**1. The floor is mostly not ours to cut.** Measured composition: `CLAUDE.md` ~7.5KB (~1.9k
tokens), `MEMORY.md` ~800B, one user skill ~370B. That is roughly **6% of the 43k floor**; the
other ~94% is system prompt, tool schemas and shipped skill listings, which no edit here
reaches. Trimming `CLAUDE.md` by 2,261 bytes bought ~1.3% of the floor. Worth doing, done — but
this item is now closed as *low ceiling*, not as solved, and it was wrong to call it the
highest-leverage item.

**1b. The floor is not one number, and it is drifting up.** Measured cold starts now span
**32,567 – 79,830** — a 2.5× spread the median hides. The high end is this environment loading
MCP servers, extra agent types and deferred tool schemas; none of it is chargeable to the
prompt. Every break-even row uses the single median, so a session that actually opened at 80k is
being priced as if it opened at 54k. Fixing this properly means recording *why* a floor is what
it is, which the CSV cannot see. For now: read the break-even table as ±40%.

**2. `rederive`.** CLOSED 2026-08-24 — n=29, median 34,066, default moved. See fourth pass.

**3. `TOKEN_REQS_PER_CYCLE` is the least-supported number in the model, and is now the top open
item** - with re-derivation measured, it is the last purely-assumed term in the break-even. It scales the carry
side of the break-even *linearly*, and it is one measurement from one session (30 deduped
requests / 13 cycles = 2.3). Halve it and the bands should be ~2× higher; double it and they
should be ~2× lower. The main awk already dedupes requests by message id, so counting them per
cycle and writing the count as a CSV column is a small change — do it before the next retune,
because no other parameter moves the bands as hard on as little evidence.

**4. The CSV cannot support cost-weighting across history.** It stores `output`, `recache` and
`context`, but not cache *reads*, so only the per-session table can print a weighted breakdown;
`--stats` and `--retune` still score raw quantities. Adding a `read` column would let the whole
history be rescored in cost-equivalents, which is the unit every decision here is actually made
in. Existing rows would simply lack the column — the parsers already skip short rows.

**5. The growth budget is a first fit, not a calibration.** 8k/15k/25k comes from 35 follow-on
cycles in one repo over three days. The tier *ratios* are guesses copied from the output tiers;
only the `feature` ceiling was fitted to the band. Revisit at the next n≥40 prompt, and check
whether `recon` at 8k is firing constantly — the median follow-on cycle grows 8,149, so a genuine
recon cycle sits right on its own ceiling.

**6. The intervention that matters has one flat measurement and no second one yet.** The
two-tier gap-warn shipped 2026-08-24 with 0 firings recorded. Do not conclude anything from
`token-gap-warn.log` until it holds >=20 rows. The question it must answer is the one the first
pass could not: of the gaps that fire the hook, how many are followed by a compact/clear or a
`/park`, and how many just carry on. If the answer is still "just carry on", the problem is not
the threshold and not the wording - it is that the advice arrives after the money is spent, and
the only remaining lever is the statusline hint at park time.

---

## Resolved (fourth pass, 2026-08-24)

**The park/gap-warn intervention measured flat, and that is the headline.** Installed
2026-08-19/20. Gap-induced rewrites (>55 min idle, >60k re-cache, per-session gap tracking):

| | cycles | gap rewrites | below the 130k gate | at cycle <=3 |
|---|---|---|---|---|
| pre-install (<=08-19) | 193 | 17 (9%) | 6 | 2 |
| post-install (>=08-20) | 155 | 15 (10%) | 7 | 7 |

Still 9% of cycles and **26% of total weighted cost** - unchanged, and by far the largest single
line in the bill. The rate did not move because **the failure mode moved and the tooling did
not follow**: pre-install it was big old sessions parked overnight, post-install it is *young*
sessions (cycle 2-3) started and walked away from for 60-110 minutes. `/park` is written for big
sessions and the hook gated at 130k, so neither one saw the new pattern. The penalty barely
scales with session age - the ~63k cold floor is most of the rewrite on its own.

Worst single case, `94dfdb3f`: three gaps (76 / 83 / 552 min) = 461k of cache writes, ~922k
input-equivalents, for zero work. The third one did clear the 130k gate.

Three changes shipped:

1. **`token-gap-warn.sh` is now two-tier.** At **60k** (about the floor) it reports the rewrite
   and pushes `/park` for next time; at **130k** it adds the compact-now advice, whose 0.56
   repeat-gap derivation is sound and unchanged. Prevention and advice were one threshold doing
   two jobs.
2. **Every firing appends a raw row to `token-gap-warn.log`** (ts, session, gap_min, context,
   checkpoint present). The hook aimed at 26% of the bill previously logged only failures, so
   there was no way to distinguish "fired and was ignored" from "never fired" - a violation of
   the project's own instrumentation rule against collectors that can silently no-op.
3. **`TOKEN_REDERIVE_COST` moved 15,000 -> 34,000** (measured median, n=29; debt item 2 closed).
   This changes the advice materially: restart now costs ~194k weighted, so the unparked
   break-even is **~224k**, not the ~192k `CLAUDE.md` claimed. With a `/park` checkpoint it is
   **~157k**. That 67k spread is the measured value of running `/park`, and it was not written
   down anywhere before this pass. `CLAUDE.md` bands updated to 157k parked / 224k unparked.

Note the direction: every corrected constant made *restarting less attractive* and `/park` more
so. The old numbers were quietly recommending session cuts that did not pay.

---

## Resolved (fifth pass, 2026-08-24)

Same day, second batch. Four findings mined from the same 354 rows, plus the changes they forced.

**1. Most gaps are self-inflicted by parallel sessions.** 19 of 32 gap rewrites (59%) had another
of the user's own sessions posting rows during the idle window. The gaps are not lunch breaks,
they are context switches: session A's cache dies while the user types in session B, and both
pay their own floor. This reframes the whole gap problem from a discipline issue into a
concurrency one. `CLAUDE.md` now caps it at two concurrent sessions.

**2. The floor is drifting up fast.** First 10 cold starts averaged 60,284; last 10 averaged
**76,661 (+27%)**. Nothing in the repo caused it - it is MCP connectors, agent types and deferred
tool schemas. Every threshold in the policy is expressed relative to the floor, so unwatched
floor drift silently invalidates all of them. Confirms debt item 1b and upgrades it from "read
the table as +/-40%" to "this needs a periodic check".

**3. The action layer has a 1.4% conversion rate.** Context dropped inside a session **5 times in
354 cycles**, while 26% of cycles ran above 200,000. Four alert signals, two hooks, a statusline
and a policy document exist to prompt `/compact` or `/clear`, and it happens roughly once every
three days. This is the real reason the fourth-pass intervention measured flat: detection was
never the bottleneck. Tuning thresholds further is provably the wrong move.

**4. Output is 34% of cost, not 7%.** The old figure came from one churn-dominated session.
Across all history with reads priced at 2.3 requests/cycle: cache writes 49.3%, **output 34.2%**,
cache reads 16.5%. And it is concentrated - the **top 10% of cycles carry 34% of all output**, so
breaches are bundled prompts, not drift. `CLAUDE.md` corrected.

**5. Cold starts are 2.5 cycles of overhead.** Mean floor 69,974 x 2 = ~140k weighted, against a
median cycle of ~57k. **25 of 53 sessions ran <=3 cycles** and hold only 14% of the work. In a
3-cycle session roughly 45% of total cost is the cost of opening the door. Cuts against the
instinct to open a clean session per question.

Changes shipped:

1. **Status line prints the cache clock**: `cache NNm` (prompt-cache life left, measured from the
   last cycle's row) and `cache COLD` once lapsed. The park/clear decision was previously a guess
   about elapsed time; it is now a lookup. `token-cycles.sh` gained `CACHE_LEFT` and
   `TOKEN_CACHE_TTL_MIN`.
2. **The `/park` hint also fires on imminent expiry** - `cache` under 10m on a window above 80k
   (`TOKEN_PARK_CROSSOVER`), which is the moment the decision is still free to make.
3. **`/park` priced from measurement**: ~23k weighted (2,604 and 3,349 output; 0.4 of a median
   cycle), not the assumed 10k. Park+clear is ~159k all-in, so the park-vs-carry crossing is
   **~80k**, not 68k. Below 80k, eating a full gap is cheaper than parking.
4. **The four-case decision table** (parked/not x warm/COLD) is now in `CLAUDE.md`, with the two
   mechanisms that make it work: the rewrite is charged on the next *request* (so `/clear` before
   typing skips it entirely), and `/park` alone saves nothing - it only cheapens `/clear`.
   Parking and not clearing is the one combination that always loses.
5. **Floor trim**: nine skills moved to `user-invocable-only` in `settings.json` (design, dataviz,
   keybindings-help, schedule, loop, run, init, security-review, fewer-permission-prompts). They
   leave the always-loaded listing but stay reachable by typing `/name`. Unauthenticated claude.ai
   connectors (Dice, Google Drive) still load schemas and can only be removed by the user in
   claude.ai connector settings - that is the larger remaining floor item.

6. **Cross-session visibility**: `token-sessions.sh` (new) prints every session's context, idle
   time and cache life, `--watch` for a live pane; the status line gained a ` | <id> <n>m`
   segment for *other* sessions within 15 min of lapsing above 60k. Written because the status
   line is per-session and the measured failure is cross-session - the one window you cannot see
   is the one costing you money. First run found a live session at 289.8k with 1 minute of cache
   left, which is a ~580k rewrite that nothing in the previous tooling would have surfaced.
   Gotcha recorded: under Git Bash `tasklist /NH` is path-mangled to `C:/Program Files/Git/NH`
   and returns nothing silently, so the liveness check must use `//NH //FO CSV`.
**7. New open item: does a cache keepalive beat a park?** A request that hits the cache refreshes
its TTL, so a trivial ping every ~50 min costs `context x 0.1` and defers the rewrite
indefinitely. At 200k that is ~20k per ping against a 400k rewrite - a medium gap (2-3h) would
favour pinging by a wide margin, an overnight gap would not (12 pings ~= 240k vs park+clear
~159k). Untested, and on a capped subscription the binding constraint is the usage cap rather
than weighted cost, so a drip while nobody is working may be strictly worse. Measure before
recommending.

---

## Review procedure

1. `bash ~/.claude/token-cycles.sh --stats`
2. Check per-signal rates against 5–25%, union against ~45–60% (four signals). The union running
   *below* that is expected here — the signals correlate.
3. Check the cold floor. If the **median** has moved materially, the 200k/300k bands move with it;
   re-derive them from the weighted break-even, never by eye.
4. Check `token-alert-errors.log` — entries mean the hook resolved no transcript, the silent
   no-op that costs a whole session before anyone notices.
5. `bash ~/.claude/token-cycles.sh --retune` before changing any threshold. It scores the whole
   history and suggests nothing; you pick.
6. Update the snapshot table above. Note what changed and why.

Testing the hook without polluting the record: `--alert` writes to `$HOME/.claude/`, so run it
with a throwaway `HOME` (`HOME=/tmp/fake bash ~/.claude/token-cycles.sh --alert < payload.json`,
with `$HOME/.claude` created first). The transcript path comes from the payload and is absolute,
so it still resolves. A synthetic two-cycle `.jsonl` — a `"type":"user"` line with a `promptId`,
then a line carrying a `usage` object — is enough to exercise every branch.
