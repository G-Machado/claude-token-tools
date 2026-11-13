# Level 1 — policy in `CLAUDE.md` (paste one block)

Paste the **core** block into `~/.claude/CLAUDE.md`, which applies to every project. Add the
**tools** block only once Level 2–3 are installed, because it refers to commands that won't
exist before then.

Edit `CLAUDE.md` at the *end* of a session. Changing it mid-session rewrites the cache.

## Core block (no tools needed)

```markdown
# Working notes — token cost

## Priorities
When these trade against each other: tokens › correctness of claims › content delivered ›
hand-off-ability › rework › my attention › time to finish. Irreversible actions (commit, push,
delete, overwrite) are verified first and never traded away.

## Cost model
Relative to input: cache read 0.05× (Opus 5.5) / 0.025× (Fable 5.2), cache write 2× (1h TTL),
output 5×. Fable 5.2 is 2× Opus 5.5 per token except cache reads (same $0.20/MTok), so on
Fable gaps, restarts, new reads and output are what cost double, while carrying a warm window
does not. The window is re-read ~5× per prompt, so window size is the biggest cost; growth (new
material read in) is the controllable part.
Pick the model per session; never switch mid-session (it rewrites the cache).

## Budget per prompt (output / new material read)
- recon (Q&A, one-file read): ~10k / ~15k
- change (scoped fix): ~20k / ~30k
- feature (multi-file, plan, investigation): ~40k / ~50k
Over on output = the prompt bundled discovery, design and implementation: split it. Over on
growth = too much was read. If a task needs more, stop at a clean point (builds/runs, or a
stated conclusion and what's next) and continue next prompt.
When a prompt bundles investigation + implementation resting on something unverified,
investigate, report and stop (use plan mode). Steps I explicitly asked for in one prompt run
to the end.

## Reading files
Cheapest rung that answers: grep -c / ls / git diff --stat → grep -n with context → ranged
read → full read. Full-read files over ~500 lines only if you intend to rewrite them. Before
any single load bigger than the growth budget, say what it costs and why the cheaper path
won't do.

## Verification and questions
I'm the cheapest way to buy certainty: ask me to check something (compile, UI, behaviour)
rather than spending tokens inferring it. Ask verification questions immediately; batch
clarifying questions for the next natural stopping point.
Label claims: "confirmed by <command / file:line>" vs "assuming X".

## Session hygiene (your job, tell me once at a clean point)
- New topic and context ≥ ~80k: suggest a fresh session with a resume note.
- Same topic past ~150k: suggest the same, once, at a clean point.
- Before I step away >1h with context > ~80k: write a resume note (task, file:line state,
  verified vs assumed, decided + why, next step) so I can /clear.
- Never suggest a restart without stating context size; below ~100k it costs more than it saves.

## Delegation
No fresh subagents for work that depends on this session's context (they start cold and
re-derive it). Fresh subagents are fine for self-contained searches whose output is a list of
paths/symbols. Use forks for noisy bounded work (test runs, build logs, wide greps) whose
output I only need summarised. Ask before launching agents.

## Persisting
A non-obvious fact about the codebase or tooling learned at token cost goes into the project
CLAUDE.md or memory in the same session — but batch those edits to the end of the session.

## Reporting
Answer first (1–3 lines), then what changed (file:line), then the basis (confirmed/assumed).
No narration of options you won't pursue.
```

## Tools block (add after installing Level 2–3)

```markdown
## Token tooling
- Measure, don't estimate: `/tokens`, `~/.claude/token-cycles.sh --stats`,
  `~/.claude/token-sessions.sh` (every session: context, idle, cache life).
- Status line `cache NNm` = minutes of cache left; `COLD` = lapsed. On COLD above ~80k,
  advise /clear before typing, then /unpark.
- Before I step away >1h above ~80k: /park then /clear. Park only while the cache is warm.
- Topic change ≥ ~80k: offer /handoff <topic> (fresh) or /compact <focus>.
- Pass hook output on: SessionStart / UserPromptSubmit hook text reaches you, not my screen —
  mention a warm-window hint, block or checkpoint in your first reply, one line.
```
