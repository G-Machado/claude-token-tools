# Token strategy — proposed refactor (2026-08-08)

Status: **fully applied 2026-08-08 — C1 through C7.** Kept for the derivation and the
`5ef7f3e5` measurement; the live record is `token-workflow-debt.md`, "Resolved (third pass)".
Numbers below are as measured at n=36 and have since moved. Companion to `CLAUDE.md` (policy),
`token-workflow-debt.md` (performance log), `token-cycles.sh` (mechanism).

Sources: the first-party Anthropic pricing/caching reference (`claude-api` skill,
`shared/prompt-caching.md`), `token-history.csv` (36 cycles / 9 sessions), and a
cost-weighted re-read of session `5ef7f3e5` from its raw transcript.

---

## The finding that reframes everything

The whole system counts **raw tokens**. Tokens are not one currency:

| class | price vs input |
|---|---|
| cache read | **0.1×** |
| input (uncached) | 1× |
| cache write, 5-min TTL | 1.25× |
| cache write, 1-hour TTL | **2×** |
| output | **5×** |

Sessions here run a 1-hour TTL, so writes are 2×. A model that adds cache reads to
cache writes to output is off by up to 50× between its cheapest and dearest term.

### Measured on session `5ef7f3e5`

| | raw tokens | ×mult | cost-equivalent |
|---|---:|---:|---:|
| output | 29,456 | 5 | 147,280 |
| cache **write** | 822,445 | 2 | **1,644,890** |
| cache read | 2,671,293 | 0.1 | 267,129 |
| **total** | | | **2,059,299** (≈ $10.30 at Opus 5 rates) |

**80% of the session's cost is cache writes.** Output — the only thing the policy
budgets — is 7%. Cache reads, the thing the occupancy alert is built to reduce, are 13%.

### And it was one tool call

At cycle 11 the `claude-api` skill loaded to answer a question about cache multipliers.
Context went 50,683 → 285,392 in a single cycle. Cost-equivalent before that call: **$1.19**.
After: **$10.30**. One skill invocation was **~87% of the entire session**, and 8× the
eleven cycles of conversation preceding it.

Note the compounding: 235k of growth produced 822k of cumulative cache *writes*, because
the enlarged window was rewritten ~3.5× afterwards. **Growth is charged at 2×, then
re-charged every time the cache misses.** It is the single most expensive thing a cycle
can do, and it is the one thing with no budget.

---

## Defects in the current model

### D1 — Restart economics are unweighted (severity: high)

```
current:   carry/cycle = context − floor − rederive        [raw tokens]
           restart     = floor + rederive                  [raw tokens]
```

The savings term is almost entirely **cache reads (0.1×)**. The cost term is a fresh
**cache write of the floor (2×)** plus re-derivation. The model compares a 90%-discounted
stream against an amplified one-off.

```
weighted:  carry/cycle = ΔC × R × 0.1        R = requests per cycle (measured 2.3)
           restart     = (floor + rederive) × 2

           N > (floor + rederive) × 8.7 / ΔC      ← ~9× the current threshold
```

At the median floor (54,189) + rederive (15,000):

| context | tool says | weighted reality |
|---|---|---|
| 100k | N > 0.9 | **N > 19** |
| 140k | N > 0.5 | **N > 8.5** |
| 220k | — | N > 4.0 ← breaks even at this repo's 4-cycle session length |
| 300k | — | N > 2.6 |

**The 100k/140k bands are roughly 2–3× too low.** They should sit near **200k / 300k**.

### D2 — `read_floor()` returns the minimum, not the median (severity: high, 1-line fix)

`token-cycles.sh:87` — `if (m=="" || v<m) m=v`. One unusually small cold start becomes the
permanent basis of every break-even number.

Consequence, visible in the record: on 2026-08-07 the debt log printed **N > 25.4** at 60k
(floor 42,729). Today the same row prints **N > 3.8** — a 6.7× swing — because one session
started at 32,567. Nothing about the workflow changed. Current spread: **min 32,567 vs
median 54,189**, a 21.6k gap that lands entirely in the optimistic direction.

### D3 — Growth has no ceiling (severity: high — this is the actual lever)

Open debt item 4, now decisively answered by the data. Output is budgeted (5k/10k/20k) and
is 7% of cost. Growth is unbudgeted and drives the 80%. Session totals: growth 506,123
against output 25,048 — **20:1**.

### D4 — Heavy loads are treated as ordinary tool calls (severity: high)

`CLAUDE.md` already flags `/update-config` at 22% of a day's usage and demotes it to
`user-invocable-only`. `claude-api` is worse (235k) and has no such guard — its trigger says
*"never answer from memory"*, which is right for correctness and catastrophic for a one-line
multiplier lookup. Same class: full reads of `.unity`/`.asset`/lockfiles, `--stats` dumps,
large transcripts.

### D5 — The occupancy signal is sold as a cost lever but is mostly a quality lever

Context re-reads are 13% of cost. Restarting to reduce them rarely pays (D1). The genuine
reasons to cut a session are **attention dilution, compaction risk, and the hard window
limit** — none of which the alert currently mentions.

---

## Proposed changes

### C1 — Weight every reported number by price
`--stats` and `--alert` gain a cost-equivalent column: `out×5 + write×2 + read×0.1 + input`.
Keep raw columns beside it; report both, judge on weighted.

### C2 — `read_floor()` min → median
One line. Removes outlier sensitivity. Re-derives every break-even row.

### C3 — Retune the context bands to the weighted break-even
`TOKEN_CONTEXT_WARN` 100k → **200k**; `TOKEN_CONTEXT_HIGH` 140k → **300k**.
Derivation: at 4 cycles/session, break-even is `(69,189 × 8.7)/4 + 69,189 ≈ 220k`.
This also resolves open debt 3 (100k firing 31%, above the 5–25% band) — it was mistuned,
and the sweep couldn't see why because it was scoring the wrong quantity.

### C4 — Add a growth budget to the policy, mirroring the output tiers
Growth is the controllable half; give it a ceiling per task class. Suggested starting point
from current medians (growth 5,375 median, 17,846 on follow-on cycles):

| class | output | **growth** |
|---|---|---|
| `recon` | ~5k | ~10k |
| `change` | ~10k | ~25k |
| `feature` | ~20k | ~50k |

Numbers are provisional — the point is that the ceiling exists, so a 235k load has to be a
decision instead of an accident.

### C5 — Pre-flight rule for heavy loads
New `CLAUDE.md` rule: before any load expected to exceed the cycle's growth budget — a heavy
skill, a full read of a large generated file, a big command dump — say what it will cost and
why the cheaper path won't do. Specifically:
- `claude-api`: scope it. A pricing/multiplier lookup should hit a small local note, not the
  full skill. **Write that note** (`~/.claude/pricing-reference.md`) — the same
  pointer-plus-bulk shape already used for `settings-reference.md` and `MODULE_SYSTEM.md`.
- Large files: grep or line-ranged read (rule exists; it needs to cover skills and command
  output too, not just files).

### C6 — Reframe the occupancy alert as quality, not cost
Say what it actually buys: less attention dilution, lower compaction risk, headroom against
the window limit. Drop the implied claim that restarting saves money at 100k — at the
weighted break-even it does not.

### C7 — Update `CLAUDE.md` and `token-workflow-debt.md`
Policy gets: the weighting table, the growth budget, the heavy-load pre-flight, the corrected
break-even formula, the new bands. Debt log gets this analysis and a fresh snapshot.

---

## What this changes in practice

- **Stop optimising session length.** It is 13% of cost and the restart math rarely clears.
- **Start optimising what enters the window.** It is 80%.
- **Output discipline stays** — 5× per token is still the dearest rate, and output remains
  the best proxy for how much work a cycle did. It is just not the biggest bill.
- **One heavy skill load can exceed an entire day of ordinary cycles.** That deserves a
  named rule, not a budget line.

---

## Sequencing

1. C2 (floor median) — one line, unblocks every other number.
2. C1 (weighted reporting) — needed to verify C3 against real history.
3. C3 (bands) — after C1/C2 rescore the existing 36 rows.
4. C5 + the pricing note — highest practical payoff, independent of the tooling.
5. C4 (growth budget) — provisional numbers; revisit at n≥40 per the existing retune rule.
6. C7 (docs) — last, once the numbers settle.

## Caveats

- n=36 cycles / 9 sessions. The existing rule (no retuning below n=40) applies to C3 and C4.
  C1/C2/C5 are correctness fixes and are not gated on sample size.
- `R = 2.3` requests/cycle is measured on one session; it scales the weighted break-even
  linearly and should be measured across the whole history before C3 is committed.
- `rederive` remains a stated parameter, not a measurement (observed 10,637–63,495, n=4).
- Cost-equivalents use Opus 5 API list rates. The Claude Code usage bar is a subscription
  allowance whose internal weighting is not published — treat dollar figures as relative,
  not as a reading of the bar.
