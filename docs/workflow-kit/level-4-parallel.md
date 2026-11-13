# Level 4 — parallel work: master + delegates (advanced)

**Only worth it for large, separable work.** For example: several independent fixes, or an
audit split by subsystem. Every lane is a session with its own cold start of ~64k, so parallel
work is never cheaper than serial. It is only *faster*. Start here only once Levels 0–3 are
routine.

## Shape

- **Master session.** Plans, writes the task for each lane, answers lane questions and
  integrates. Started with `/master`.
- **Delegate lanes.** One self-contained task each, in its own git worktree (`/delegate`), or
  in the same checkout with `/delegate --shared` when it needs the one live editor or tool.
  Lanes ask questions through `/answer`.

## Rules that keep it cheap

1. **The master never reads raw lane output.** Each lane ends with a `## Summary` table. The
   master integrates from those tables only.
2. **Targets:** master window **≤ 100k** at every integration point, each lane **≤ 150k**,
   **zero gap rewrites**.
3. **At most three sessions live at once**, master included. The post-mortem that set these
   rules: six concurrent lanes, two windows renewed past 226k, one 373k-weighted gap rewrite,
   $12.8 for one review.
4. **Lane claims a lane didn't verify are labelled, not promoted** to findings.
5. **The metric is $ per confirmed finding**, meaning a finding you acted on or re-verified and
   kept.

## With Fable and Opus

A natural split is a **Fable master** (short window: planning and integration) with **Opus
lanes** (long windows: implementation). The master's window stays small by rule 1, which is
what keeps the 2× Fable price affordable.

This split is unmeasured. Check it against `--stats` after a few runs.

## Install

Installed by `install.sh` (`/master`, `/delegate`, `/answer`, `token-master.js`). Optional
hook: `PreToolUse` with matcher `Bash|Edit|Write|MultiEdit|NotebookEdit`, running
`node "$HOME/.claude/token-guard.js"`. In master mode it refuses `cat`/`sed`/`head` of a lane
file over 8 KB (`TOKEN_MASTER_READ_KB`). `grep` still passes.

The same script also carries the author's own safety rules, which apply everywhere:

- deny a commit without an explicit `-- <paths>`
- deny `--no-verify`
- ask before a force-push
- block `dotnet build` inside a Unity project, and ask before editing `.unity` / `.prefab` / `.asset`

Read its header and decide whether those fit your work before wiring it.
