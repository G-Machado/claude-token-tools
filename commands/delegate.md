---
description: Hand one self-contained task to a parallel session in a git worktree (or --shared, this checkout); this one stays live
argument-hint: "<topic-slug> [--shared] [what to do]"
allowed-tools: Bash(bash:*), Bash(git:*), Bash(powershell:*), Read, Write, Edit
---

!`bash "$HOME/.claude/token-park-context.sh"`

Give one task to a new session that works it on its own branch in a git worktree and writes a
report, while this session carries on. Like `/handoff`, but nothing here is parked, blocked or
left to lapse. The user typed: **$ARGUMENTS**

Glue over pieces that already exist - do not reimplement any of them. If the task is not clear
from the argument and this window, or it is not self-contained (it needs decisions only this
window can make as it goes), say so and stop: a delegate cannot ask back. **Exception: this
session is a master** (`node "$HOME/.claude/token-master.js" status` says `master`). Its delegates
ask with AskUserQuestion, TokenChat routes the question here, and `/answer` replies, so a task that
may need a question or two is fine.

**Mode.** Worktree by default. **`--shared`** (typed anywhere in the argument; drop it from the
task text) runs the delegate in this checkout instead: no worktree, no branch, no commits. Use it
whenever the project is a Unity project (`Assets/` and `ProjectSettings/` at `<root>` or `<sub>`'s
project dir) **and** the task needs the Editor (scenes, prefabs, play mode, builds, tests, any C#
the Editor compiles): one Editor, ever - a worktree would mean a second Editor and a cold Library
import. Worktree only for Editor-free work (docs, tools outside `Assets/`). If the user did not
type `--shared` but both hold, use it and say so in the reply.

## 1. Pick the names

- `<slug>`: the argument's first word if kebab-case, else a new 2-3 word slug for the task. It must
  not match a listed checkpoint, a `delegate/<slug>` branch (`git branch --list`) or an existing
  directory; on a clash say which and stop.
- `<root>`: `git rev-parse --show-toplevel`; `<sub>`: `git rev-parse --show-prefix` (cwd within it).
- `<worktree>`: `<root>/../<basename of root>-<slug>`; the delegate's cwd is `<worktree>/<sub>`.
- `<proj>`: the basename of the delegate's cwd (`/unpark` lists checkpoints by it). Equal to this
  one's unless `<sub>` is empty.
- `--shared`: no `<worktree>`, the delegate's cwd is this session's cwd, and the branch clash
  check is skipped.

## 1b. Reuse a warm delegate first

A finished delegate that is still warm already knows the ground; a new session re-derives it
(cold start median 33.6k growth + 14.5k output, `park.md` §2). Before opening a new one, look:

```
"$HOME/.claude/token-sessions.sh" --json
```

A candidate meets all of these: `alive` 1, `running` 0, not this session; `cwd` is the project
checkout (this one, not a worktree); it has finished (a `checkpoints/reports/*.md` header carries
its `sid=`); `cache_left_min` ≥ 10; `context_k` < 150 (the same-topic quality bar); and the task
continues ground it worked (its report's Done touches the systems the task needs). Best: most
cache left, then smallest context.

With a candidate, reuse it: run the rest in `--shared` mode (its cwd is the delegate cwd; `<proj>`
from it) even if the user did not type `--shared`, provided the Scope is disjoint from every live
delegate's (the `--shared` check in 2); otherwise open a new one and say why. Write the brief (2),
skip 3 and 4, and log the event:

```
printf '%s\treuse\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" <slug> <this session id> <its sid> "<its cwd>" >> "$HOME/.claude/token-delegate.log"
```

Hand it over with `SendMessage` (load it via ToolSearch), `to` = its `name` as `ListAgents` shows
it: first line "New delegate task: run the `unpark` skill with args `<slug> --delegate`", then the
brief path, its Scope and the report path. Never type into its tab. A `[Cross-session delivery
notice]` that it was held or refused → fall back: the reply asks the user to paste
`/unpark <slug> --delegate` into that tab. Either way name it by `name` and short sid, with its
`context_k` and `cache_left_min`. No candidate: carry on with 2.

## 2. Write the brief

`$HOME/.claude/checkpoints/<proj>.<slug>.md`, in the checkpoint format of
`$HOME/.claude/commands/park.md` section 2 (read it now; it is the one source), with these changes:

- First line: `<!-- park: session=<this session id> topic=<slug> cwd=<delegate cwd> delegate-of=<this session id> -->`.
  From a master, append ` master=<this session id>` before ` -->`. A later handover rewrites it;
  an old sid still resolves to the current master (`token-master.js resolve`, `decided`).
- **Next**: the task as concrete steps; **Stop after**: the done-criteria, checkable.
- **`Pass test:`** one line under Stop after: a check a machine can read (a log line, an exit
  code, a screenshot mean, a grep count), with the command. Rounds then run without the user's
  eyes, which are asked for only at decision points. No such check exists: say so on the line.
- **`## Summary` contract** (2026-11-11; mandatory, write it into Next as the last step): every
  output file the delegate writes opens with a `## Summary` table, `id | severity | title |
  where`, one row per finding or change, **≤ 40 lines**, nothing a master has to open the file
  to understand. The master integrates from that table alone - `token-readguard.js` /
  `token-guard.js` refuse it a whole read of `_build/**` over 8 KB in master mode - and the
  done-card carries it. A report without one is sent back for one, not read around.
- **Goal** adds `Scope:` the files and dirs it may touch; everything else is read-only.
- **Decided** carries the constraints from this window the delegate must not reopen.
- **State**: `git: delegate/<slug> @ <HEAD short>`. The worktree starts at HEAD: **uncommitted
  work here is not in it.** If the task depends on it, say so and stop rather than delegate.
- **Waiting on the user**: none; a delegate that needs the user writes its report and stops.
  From a master: `none - ask the master with AskUserQuestion (one question per card, options
  first); it answers in this tab. Before asking, run token-master.js decided --master <master sid>
  (its live Decided + every answer so far); ask only what the brief and that leave open.`
- **`--shared`**: header also gets ` shared=1` before ` -->`. **State**: `git: <this branch> @
  <HEAD short>, shared checkout - no commits, the master commits`. Uncommitted work here *is*
  visible to it. **Scope** names the exact `.unity` scenes and prefabs it owns, disjoint from every
  other live delegate's Scope (check their briefs); on an overlap say which and stop. **Decided**
  adds: `Editor lease: token-master.js lease take --wait --slug <slug> before any write under
  Assets/, scene open/switch, play mode, build or test (exit 3: still queued, run it again; never
  ask for the lease); lease release after the step. Unity CLI reads are free.`

## 3. Make the worktree (skip for `--shared`)

```
git -C "<root>" worktree add "<worktree>" -b delegate/<slug>
```

On failure, delete the brief and report the error.

## 4. Open the delegate

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/token-unpark-new.ps1" -Topic <slug> -Cwd "<delegate cwd, Windows form>" -Mode delegate -ParentSid <this session id>
```

No `-OldSid`: this tab is not taken over and this session is not set to lapse. `-ParentSid` only
logs the `open` event in `$HOME/.claude/token-delegate.log`. Add `-Model <id>`
only if the user named one, or this is a master picking one by its routing table
(`commands/master.md`). **Exit 2** means nothing opened: remove the worktree and branch
(`git worktree remove`, `git branch -D`; none for `--shared`), delete the brief, report its output.

From a master, run `node "$HOME/.claude/token-master.js" add-delegate <slug>` **before** opening:
it is the admission check (2026-11-11). Exit 3 = refused - more than 3 of this master's delegates
alive, or the active account's 5-hour headroom under ~15% per live delegate plus this one - and
its message names the fix (`cswap switch <n>` to the spare account, retire one, or wait). Do not
open on a refusal; `--force` only if the user says so. Delegates open on the lean profile
(`--lite`: core tools + Skill, no MCP schemas; `TOKEN_DELEGATE_LEAN=0` for full).

## 5. Reply

One line: branch `delegate/<slug>` and the worktree path (`--shared`: "shared checkout, Editor
lease"), and that the report will land at
`$HOME/.claude/checkpoints/reports/<proj>.<slug>.md` (a card in this tab in TokenChat). Then carry
on with whatever this session was doing.

Reuse (1b): instead, which tab took it (`<name>`, sid `<short>`, `<context_k>`k, cache `<n>` min
left), sent by message or — if held/refused — the paste line for the user, and the report path; if
reuse switched the mode to `--shared`, say so.
