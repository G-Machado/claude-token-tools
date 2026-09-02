# claude-token-tools

A token-cost dashboard and budget enforcement layer for [Claude Code](https://claude.com/claude-code).

Claude Code tells you nothing about what a session costs while you are in it. These tools
read what the CLI already writes to disk and turn it into three things: a **status line** that
prices the session you are typing into, a **live pane** that watches every session on the
machine at once, and two **hooks** that speak up at the two moments where money is actually
lost — a prompt cycle that pulled in far more than it needed, and a big session resumed after
its prompt cache expired.

Everything is bash + awk reading local files. **No API calls, no model tokens, no network.**

---

## The problem it solves

Claude Code's prompt cache lives one hour. Reading from it costs `0.1x` an input token;
writing to it costs `2x`. That is a **20x swing on identical content**. Walk away from a
200k-token session for ninety minutes, come back and type one word, and you have just paid
~400k input-equivalents before the model has read your sentence.

Measured here over 354 cycles:

| where the money went | share |
|---|---|
| cache writes | 49% |
| output | 34% |
| cache reads | 17% |

And gap-induced rewrites — sessions parked across the cache TTL — were **9% of cycles but 26%
of total weighted cost**. They also repeat: a session parked once tends to get parked again.

None of that is visible from inside Claude Code. This repo makes it visible, and then tells
you which of three things to do about it (carry on / park / clear).

---

## What you get

### `token-cycles.sh` — the per-cycle meter

A *cycle* is one user message plus every tool call until control returns to you. The script
scores each one against two budgets:

- **output** (thinking + text + tool arguments) — the signal for how much work the cycle did
- **growth** — how much *new* material got pulled into the window, charged at the 2x cache-write
  rate and re-charged on every later cache miss

Two budgets because they are different failures. Over on output usually means one prompt
bundled discovery, design and implementation. Over on growth means too much was read.

Runs three ways: as a table (`token-cycles.sh [tier]`), as the **status line**
(`--status`), and as a **Stop hook** (`--alert`) that warns on a breach and appends one raw
row per cycle to `token-history.csv`. The history stores measured quantities only — never a
bucket or a verdict — so retuning a threshold never invalidates it and `--stats` rescores
whatever is already on disk.

### `token-sessions.sh` — the live pane

Every Claude Code session on the machine, sorted with the one about to lapse at the top.
Per row: context size, spend so far split green/orange/blue (output / cache writes / cache
reads), a growth sparkline, an A–F grade, and **minutes of prompt-cache life left**.

Each row also carries a verdict glyph — act now / a cut would pay / nothing to decide — off
the same ladder the advice line underneath is written from. `--watch` redraws in place and
takes keys live; `--analytics` opens the history tab (where the spend went, median and p90 per
cycle, a 14-day sparkline, breach and gap-rewrite rates, 7d-vs-before with arrows).

It exists because the expensive failure is **cross-session**: 59% of measured gap rewrites had
another of your own sessions active during the idle window. The window you cannot see is the
one costing money.

### `token-gap-warn.sh` — the gap hook

A `UserPromptSubmit` hook. Silent unless you have just resumed a large session after a long
idle. It tells apart *about to lapse* (act now and save the pass) from *already lapsed* (the
2x rewrite is sunk — compacting right now is the salvage, and this is the cheapest moment
there will ever be to do it). Fires in two tiers, 60k and 130k, and logs every firing.

### `/park` and `/unpark` — the checkpoint pair

`/park` writes a resume checkpoint — task in flight, `file:line` state, verified vs assumed,
next step — to `~/.claude/checkpoints/<project>.<topic>.md`, then tells you whether to
compact, clear, or leave the session open. `/unpark` picks it back up in a fresh session
without re-deriving.

The point is the arithmetic: re-derivation after a `/clear` measured **34,066 tokens without a
checkpoint** (n=29) and **~5k with one**, which is what makes clearing cheap enough to be the
right move at all.

### `/tokens`

Per-cycle cost for the session you are in, in-conversation.

---

## Quick start

```sh
git clone <this repo> claude-token-tools
cd claude-token-tools
./install.sh
```

Then merge the printed `statusLine` + `hooks` block into `~/.claude/settings.json` and restart
Claude Code. Full walkthrough: **[docs/INSTALL.md](docs/INSTALL.md)**.

The views are thin until the Stop hook has written ~20 cycles of history. Give it a day of
normal use before judging any number.

## Requirements

- Claude Code, run at least once (so `~/.claude/` exists)
- **bash 4+** and **awk** — Git Bash on Windows, or any Linux/macOS shell
- Optional: `mintty` for the styled desktop window (`config/token-sessions.minttyrc`)

Developed on Windows 11 + Git Bash. The paths are all `$HOME`-relative and nothing is
Windows-specific except the clipboard (`y`) and desktop-notification helpers, which degrade
quietly.

## Where to go next

| | |
|---|---|
| **[docs/INSTALL.md](docs/INSTALL.md)** | install, wiring, verification, uninstall |
| **[docs/TUTORIAL.md](docs/TUTORIAL.md)** | a week with the tools, from first run to retuning |
| **[docs/REFERENCE.md](docs/REFERENCE.md)** | every flag, key, column, env var, data file |
| **[docs/COST-MODEL.md](docs/COST-MODEL.md)** | the policy the tools enforce — park/clear thresholds and where they come from |
| **[docs/workflow-debt.md](docs/workflow-debt.md)** | whether the policy actually works, and what is known wrong with it |
| **[docs/pricing-reference.md](docs/pricing-reference.md)** | price multipliers, cache TTL and invalidation rules |
| **[docs/failsafe-findings.md](docs/failsafe-findings.md)** | why automatic cache renewal is impossible — do not re-derive this |
| **[docs/strategy-refactor.md](docs/strategy-refactor.md)** | the original derivation of the budget tiers |
| **[docs/briefing.md](docs/briefing.md)** | full system briefing, written for another agent to cross-check |
| **[docs/settings-reference.md](docs/settings-reference.md)** | condensed `settings.json` reference |

## A caveat about the numbers

Every threshold in here — the ~63k cold floor, the 157k/224k restart bands, the 80k parking
bar, the tier budgets — was **measured on one machine, on one plan, doing one kind of work**
(a Unity project, Opus 5, ~6.6 cycles per session). They are a defensible starting point, not
constants. `token-cycles.sh --stats` and `--retune` rescore your own history; the derivations
in `docs/` show the working so you can redo it against your own data rather than trusting mine.

Cache reads are **modelled** (context x 2.3 requests per cycle), not measured — the CLI does
not report them per cycle. Everything else in the cost column is counted.

## License

MIT — see [LICENSE](LICENSE).
