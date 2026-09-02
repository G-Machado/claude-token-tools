---
description: Token cost per prompt cycle for this session
allowed-tools: Bash(bash:*)
---

!`bash "$HOME/.claude/token-cycles.sh" $ARGUMENTS`

Scored against the tier named in `$ARGUMENTS` — `recon` (5k), `change` (10k, the default when
no tier is given), `feature` (20k) — or a bare number. If the user named no tier, judge from the
cycles themselves whether the default bar was the right one to score against.

The table above is already shown to the user — do not restate it, summarize it, or
re-list the numbers. Add only four labelled lines beneath it, no preamble:

**Budget** — average output per cycle, and which cycles went over (or "all clear").
**Driver** — the re-cached-to-output ratio, and which cycles carried the spikes.
**Context** — current window occupancy against the warn/high bands shown in the summary
line, and whether it's climbing cycle over cycle.
**Action** — one concrete next step, or "none needed".

Read the bars, not just the totals. A long context bar beside a short work bar means the
cost was session length, not the prompt — the fix is a fresh session, never a shorter
prompt. Cycles showing 0 output were interrupted, not free.

The table lags by one cycle; the current cycle is not written to the transcript yet.
