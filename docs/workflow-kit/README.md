# Cost-effective Claude Code — a setup kit in levels

Pick the highest level you are willing to maintain. Each level assumes the ones below it. Most
of the saving is in **Level 0 and Level 1**, which need no installation at all.

| level | what you get | install effort | file |
|---|---|---|---|
| **0 — habits** | the rules that move the bill most, applied by you | none | [level-0-habits.md](level-0-habits.md) |
| **1 — policy** | the same rules in `CLAUDE.md`, applied by the model | paste one block | [level-1-claude-md.md](level-1-claude-md.md) |
| **2 — measure** | status line with cache clock, per-cycle history, `/tokens` | `install.sh` + 2 settings keys | [level-2-measure.md](level-2-measure.md) |
| **3 — guards** | gap warnings, read guard, hard stop, `/park` `/unpark` `/handoff` | more hooks | [level-3-guards.md](level-3-guards.md) |
| **4 — parallel** | master session + delegate lanes | advanced, opinionated | [level-4-parallel.md](level-4-parallel.md) |

Recommended start: **Level 0 + 1 on day one, Level 2 after a week** so you have your own numbers
before tuning anything. The figures throughout come from about two months of one developer's
sessions, mostly on Opus. Treat them as starting points, not as constants.

## Why it works — the bill in five lines

Here is what each token costs, in dollars per million tokens (checked 2026-11-12) and relative
to that model's uncached input price:

| | Opus 5.5 | Fable 5.2 |
|---|---|---|
| cache read | $0.20 (0.05×) | $0.20 (0.025×) |
| input | $4 (1×) | $8 (1×) |
| cache write, 1-hour | $8 (2×) | $16 (2×) |
| output | $20 (5×) | $40 (5×) |

The whole conversation window is re-read about **5 times per prompt**, so **window size is the
biggest line on the bill**.

The cache lives **one hour**. After a longer pause, the next message rewrites the whole window
at 2×, and that costs **40×** what a cache hit would on Opus, **80×** on Fable. Measured spend split: rewrites 38%,
reads 33%, output 28%.

So the three levers are:

- **Read less**: keep the window small.
- **Don't let big windows go cold**: avoid gaps.
- **Don't bundle**: keep output down per prompt.

## Using Fable and Opus together

**Pick the model per session, never mid-session.** A model switch (`/model`, or `opusplan`
toggling in and out of plan mode) starts a fresh cache: a 127k window was measured as a full
rewrite. Changing **effort** mid-session is free (measured, no cache break).

**Fable 5.2 costs 2× Opus 5.5 on everything except cache reads, which cost the same $0.20.**

So on Fable:

- Keeping a warm window open costs no more than on Opus.
- What doubles is everything that writes or generates: output and thinking, new material read
  in, gap rewrites, and the cold start of every new session.

Applying the measured Opus spend split (reads 33%, writes 38%, output 28%), the same work costs
about **1.65× on Fable**. That figure is an estimate: it assumes Fable uses tokens the way Opus
does, and that is unmeasured.

| | Opus 5.5 | Fable 5.2 |
|---|---|---|
| default for | routine implementation, refactors, fixes, recon | hard design, gnarly debugging, review of risky changes |
| session shape | normal | **keep it warm and keep it going**: a gap or a restart costs 2×, carrying the window does not |
| watch most | window size | **output**: thinking at `xhigh` is the 2× line, so use `high` unless the task needs more |

- **On a subscription (Pro/Max), plan usage is the limit, not dollars.** Claude Code's own
  notice says Fable "draws down usage faster than Opus 5.5". The proportions above are the best
  available guide to *how much* faster. Anthropic doesn't publish the exact plan weighting.
- **Hand off between models with a checkpoint**, not by switching. Park the Opus session (Level 3
  `/park`, or ask for a written summary at Level 0), then open a Fable session on it. The new
  window pays the cold floor (~64k) plus the checkpoint at Fable's write price, against the whole
  old window rewritten. Moving in the Fable → Opus direction is the cheap one.
- **Subagents.** A *fork* always runs on the parent's model and reads the parent's cache. A fresh
  subagent can be given a cheaper model, but it pays its own cold start. From a Fable session,
  give a fresh subagent a self-contained search (output = a list of paths) on a cheaper model.
  Use a fork for noisy work that needs the context.
- **Effort**: `high` is a sensible default for both. `xhigh` cycles averaged more requests (9.0 vs
  6.6), and every extra request re-reads the window. Task mix confounds that comparison.
- **Thresholds were measured on Opus.** Fable's cold floor and per-cycle numbers are unmeasured.
  If you install Level 2, run `token-cycles.sh --stats` after a week of Fable work and adjust.

## Background

[../WORKFLOW.md](../WORKFLOW.md) has the full reasoning and the numbers with dates.
[../COST-MODEL.md](../COST-MODEL.md) has the derivations: restart break-even, park thresholds,
and why keep-alive pings don't work.
