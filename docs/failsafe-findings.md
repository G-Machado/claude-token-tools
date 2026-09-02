# Why the cache fail-safe was retired

Established 2026-08-27 at real cost: one uncontrolled ping at ~215k weighted,
plus ~75k of controlled probes. Do not re-derive it — re-run
`token-failsafe-probe.sh` only if the CLI's caching behaviour changes.

## The finding

**A `claude -p` process shares exactly ~18,690 tokens of system prompt with any
interactive session. Everything after that diverges and is rebuilt at 2x.**

Measured against two parents that differ in size and in mode:

| parent | window | matched | recovery |
|---|---|---|---|
| VS Code session | 47,029 | 18,690 | 40% |
| plain terminal session | 34,027 | 18,690 | 55% |

Same head, to the token. The boundary is **print-mode vs interactive**, not
IDE vs terminal — an early guess that it was the IDE was wrong, and the terminal
test is what disproved it.

## Two separate defects, both real

1. **`--fork-session` throws away the session id.** The conversation-level cache
   segment is keyed to it, so a fork's head drops from 18,690 to ~13,000 and
   everything below is rebuilt. Genuinely fixed by plain `--resume`, which
   recovers **100%** against a print-mode parent.
2. **`-p` cannot reproduce an interactive system prompt.** Not fixable from a
   bash pane. This is the binding constraint and it caps the head at 18,690.

## Why it is fatal rather than merely inefficient

Cache entries are keyed by exact prefix:

    live session: [interactive system][conversation][next message]
    the ping:     [print system]      [conversation][keepalive]

They diverge at 18,690. The ping therefore refreshes a **parallel entry the live
session will never send**. Only the shared head has its clock reset; the rest of
the session's prefix ages out on schedule. Each ping costs more than the head it
keeps warm, at every window size — so no renewal cap makes it pay. Retiring
beats tuning.

## What was verified and is safe, if this is ever revisited

- Appending to a live session's transcript is **safe**: no exclusive lock on
  Windows, prefix stayed byte-identical, 0 malformed records, tested against
  both a VS Code and a terminal session.
- **Truncating it is not.** A truncate-back cleanup destroyed 2 of 20 records a
  concurrent writer had appended. Check-then-truncate is a race and can cut
  mid-line. Rejected.
- The old verdict test (`cache_read > cache_creation`) is wrong: it graded a 50%
  recovery a pass, because the ping adds a turn and always writes a fresh block.
  Score recovery against the **parent window** instead.
- With plain `--resume` the ping returns the **parent's** session id, so the
  fork-cleanup `rm` must be guarded or it deletes the live transcript.

## Working alternative, for the record

A print-mode session (`claude -p --resume` in a loop) *can* be held open at 0.1x
indefinitely. It costs the entire interactive layer — permission prompts,
streaming, slash commands, IDE integration — to get there. Noted as the boundary
of the result, not as a recommendation.

## What still works and was kept

The pane's warning bell, the `cache NNm` clock, and the park/clear advice. Those
tell you to act while acting is cheap, which is the part that was never broken.

## Retired 2026-08-27

The pinger is gone from `token-sessions.sh`: `start_ping`, `failsafe_tick`,
`failsafe_reap`, the arm/disarm table and its lock, and the `f` key. The old
`token-failsafe.sh` and the `/failsafe` command moved to `retired-failsafe/`
rather than being deleted, and `token-sessions.sh.bak-retire` is the script as
it stood immediately before.

What replaced it: `notify()`, a Windows balloon fired from `ring_bell` on the
same gate the bell uses - a live window inside `TOKEN_BELL_MIN` minutes of
lapsing and above the parking bar, once per session per lapse. It names the
session by its first prompt and says what to do. `TOKEN_POPUP=0` silences it.

`token-failsafe-forks.txt` stays: `token-failsafe-probe.sh` still writes to it
so its throwaway sessions stay out of the medians and grades.

---

# Cache economics established alongside this, 2026-08-27

Kept here because they cost the same investigation to establish and are the
reusable half of it.

## A cache hit is 0.1x. A cache MISS is 2x. The pinger only ever bought misses.

The confusion worth naming: 0.1x applies to tokens **read** from cache. The
failed ping did not read 106k, it **wrote** it.

    cache_creation  106,653  x 2.0  =  213,306
    cache_read       12,975  x 0.1  =    1,298
                                       -------
                                       ~214,600 input-equivalents

A *successful* renewal of that same window would have been ~14,500. Same
operation, 14x apart, and the only difference is whether the prefix matched.

## You are the cheapest keepalive there is

Typing one word into a live session reads its real prefix at 0.1x:

| | weighted |
|---|---|
| you type "ok" into the session | **~15k** |
| the retired pinger | **~215k** |

Confirmed against a real cycle row - `1c7a3ccb` cycle 4 wrote only 4,478 tokens
and read ~141k, so a bare keystroke lands at ~15k. It is not merely cheaper, it
is *correct*: your keystroke touches the entry the session will actually send.

Limit: it only works while you are at the keyboard. It covers a call or a
coffee, never a night. That is what /park + /clear is for, and it is why the
pane's toast offers both.

## What a working keepalive would have been worth

~15k/hour to hold, against a flat ~159k for /park + /clear, so the break-even
sits near **10 hours**. The concept was sound; only the mechanism was not.

## The floor moved, and every threshold moves with it

`token-cycles.sh --stats`, 2026-08-27: cold floor **median 79,077** over 25
fresh starts. Older notes say 63k. The post-gap rule is:

    clear after a gap when   context > floor + re-derivation

so the thresholds are *derived*, never fixed, and a rising floor pushes them UP
(clearing gets less attractive, because restarting costs more):

| | at floor 63k | at floor 79k |
|---|---|---|
| parked (~5k re-derive) | 68k | **~84k** |
| not parked (~34k re-derive) | 97k | **~113k** |

The floor can never exceed the threshold - the threshold *is* floor plus
re-derivation. Read the live number, never a constant from a document.

**And note what the 34k is:** `--stats` prints it as *assumed 34,000 | measured
median 0 over 49 resumed sessions*. The unparked threshold is an unvalidated
model constant, not a measurement. The parked/unparked gap is exactly that
assumption, so treat ~113k as soft.

## Re-derivation is bounded by the NEXT task, not by the window

A 200k session stopped at a clean point re-derives cheaply; a 100k session
stopped mid-investigation does not. This is the whole reason /park works: it is
the act of making the next task's needs explicit, which converts an unbounded
quantity (all the context) into a bounded one (a checkpoint).

## Tooling note for anyone editing these scripts

**Heredocs through the Claude Code Bash tool eat backslashes.** A pattern
written `\n` arrives as a real newline and a trailing `\` collapses the line,
so patch scripts silently fail to match or corrupt their own output. It broke
three attempts in one session. Build backslashes with `chr(92)` and avoid shell
line-continuations in generated code entirely.
