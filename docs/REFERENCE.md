# Reference

Every flag, key, column, environment variable and data file. The authoritative copy of each
script's own usage is its header block — `--help` prints it, so a flag cannot go undocumented
while still working.

---

## `token-sessions.sh` — the live pane

```sh
token-sessions.sh                     one snapshot, live sessions only
token-sessions.sh --watch [secs]      live pane, redraws in place (default 60s)
token-sessions.sh --browse            live pane, opened on the detail panel
token-sessions.sh --analytics         history: where the spend went, and whether it improves
token-sessions.sh --weekly            analytics in weeks rather than days
token-sessions.sh --all               include sessions whose process has exited
token-sessions.sh --compact           one line per session, no titles
token-sessions.sh --sort NAME         lapse (default), context, cost, active, project
token-sessions.sh --filter TEXT       only sessions matching name/project/prompt/path
token-sessions.sh --checkpoints [proj]  what is parked, newest first ("all" for every project)
token-sessions.sh --classic           the older rounded frame and softer palette
token-sessions.sh --ascii             no box-drawing or block glyphs
token-sessions.sh --no-color          plain text
token-sessions.sh --help              the header block, plus the key table
```

### Keys in `--watch` / `--browse`

| key | does |
|---|---|
| `j` `k` | move the selection, or scroll the list |
| `1`-`9` | jump to a row — type two digits past nine |
| `g` `G` | first row / last row |
| `/` | filter by name, project, prompt or path |
| `/n NAME` | name the selected row yourself; bare `/n` undoes it |
| `s` | re-order: lapse, context, cost, active, project |
| `d` | expand the selected row into the full panel |
| `y` | copy `claude -r <id>` to the clipboard |
| `o` | open the checkpoint, or the transcript folder |
| `n` | re-roll this row's name, or clear one typed with `/n` |
| `D` | move a closed session log to `deleted-sessions` |
| `t` | analytics: the whole history |
| `[` `]` | analytics: page through the sections |
| `w` | analytics: daily or weekly buckets |
| `a` | include closed sessions |
| `c` | compact rows, drop the prompt titles |
| `b` | mute or unmute the lapse bell |
| `r` | collect now rather than on the clock |
| `esc` | back one step |
| `?` | the key list, and the column key |
| `q` | quit |

`/` and `s` are pure **view state** — they rewrite the view of the snapshot rather than
re-reading disk, so they land on the next redraw and cost nothing.

### Naming a row

`/` opens a small command line, not only a filter box — a second prompt key would be one more
thing to find. A line starting with `n` renames the selected row instead of searching.

```
/n build-fix              names the selected row build-fix
/n unity scene merge      arrives as unity-scene-merge
/n                        back to the derived name
/ n                       filters for the letter n (the space says: search)
```

Rules:

- The name is the rest of the line, trimmed, with runs of blanks collapsed to single dashes, so
  it stays one token and the column stays a column. Cut to 24 characters.
- `|` and tab are stripped — the snapshot is pipe-separated and `token-nicks.tsv` is
  tab-separated, so neither may reach a stored name.
- A typed name **outranks every re-roll variant**. `n` clears it and hands the row back to the
  derived pool at the variant it left off on, so one key both undoes `/n` and resumes re-rolling.
- With nothing selected, the top row is meant — the same rule `n` follows.
- Nothing here writes to `sessions/<pid>.json`. The CLI's name for a session stays the CLI's,
  in its own column two along.

Stored as a third field in `token-nicks.tsv` (`sid <TAB> variant <TAB> typed-name`). The field
is optional, so older two-field rows keep working.

### Columns

| column | means |
|---|---|
| **context** | window size. Length *and* colour are both size and nothing else: dim green under the ~63k floor, green under the parking bar, yellow past it, orange once a cut would pay with a checkpoint on disk, red once it would pay without one. What the window costs *right now* lives in **cache**, not here. |
| **cost** | spend so far in input-equivalents (output x5, cache write x2, cache read x0.1). The bar splits it green output / orange cache writes / blue cache reads. More green is better — that is the share that went into doing work rather than paying rent on a window. |
| **growth** | one glyph per cycle, up to twelve, on a fixed scale so the column means the same on every row. Red over the growth budget, amber over the output budget. |
| **grade** | spend / production / control for that session, against what your machine actually does. Spend is measured **above** the cold floor, because that write is not a choice. |
| **cache** | minutes of prompt-cache life left, and nothing else. |

**Cache reads are modelled** (context x `TOKEN_REQ_PER_CYCLE`), not measured — the CLI does not
report them per cycle. Everything else in the cost column is counted.

### Row markers

| glyph | means |
|---|---|
| moving bar | a turn is running right now (a solid arrow in the one-shot form) |
| hollow arrow | the most recently touched session |
| diamond | a `/park` checkpoint is on disk for this window |
| filled triangle | **verdict:** act now |
| hollow triangle | **verdict:** a cut would pay if you want it |
| dim ring | **verdict:** nothing to decide |

While anything is running the pane redraws four times a second and re-reads disk every ten, so
a marker cannot go on moving for a turn that has already finished.

---

## `token-cycles.sh` — the per-cycle meter

```sh
token-cycles.sh [tier|number]   table for this session, scored against a tier
token-cycles.sh --status        status-line mode
token-cycles.sh --alert         Stop-hook mode: reads hook JSON on stdin, prints only on breach
token-cycles.sh --stats         history across sessions: how often the hook fires, and why
token-cycles.sh --retune        re-derive the budgets from your own history
```

### Tiers

| tier | output | growth | for |
|---|---|---|---|
| `recon` | 5,000 | 8,000 | Q&A, single-file read, orientation |
| `change` | 10,000 | 15,000 | a scoped change or fix — **the default** |
| `feature` | 20,000 | 25,000 | multi-file feature, plan, investigation |
| `scene` | 20,000 | 60,000 | huge low-density files (Unity scene YAML). **Provisional — guessed at n=0** |

Aliases: `read`/`qa`/`q` → recon; `fix`/`edit` → change; `plan`/`investigate`/`big` → feature;
`merge`/`unity` → scene. A bare number passes through.

`scene` is a **tier, not a per-file exemption**. An exemption would forgive a careless full read
during ordinary `change` work, which is the failure the budget exists to catch.

### The history file

`--alert` appends one raw row per cycle to `token-history.csv`. That write happens inside a hook
that already runs every cycle, so **collecting costs no model tokens** — only reading `--stats`
does.

Rows carry measured quantities, never a bucket or a verdict. Retuning a threshold therefore
never invalidates a row, and `--stats` rescores whatever is already on disk.

---

## `token-gap-warn.sh` — the gap hook

A `UserPromptSubmit` hook. No flags — it reads hook JSON on stdin and the same
`token-history.csv` the Stop hook writes.

Silent unless a large session was resumed after a long idle. Two tiers:

- **60k** (about the cold floor) — reports the rewrite and pushes `/park` for next time. This
  tier exists because 7 of the 15 gap rewrites after install sat *below* 130k, at cycle 2-3 of
  young sessions: the penalty barely scales with session age, since the floor is most of it.
- **130k** — adds the compact-now advice, which is where that advice is finally in its favour.

It fires at 55 minutes against a 60-minute TTL, so a firing is not proof of an expiry, and it
says which case it was. Every firing appends a row to `token-gap-warn.log`.

---

## Slash commands

| command | does |
|---|---|
| `/tokens` | per-cycle cost for the session you are in |
| `/park` | write a resume checkpoint, then advise compact / clear / leave-open |
| `/unpark` | resume from a checkpoint after a `/clear`, without re-deriving |

`/park` and `/unpark` each build their context block in a **file** (`token-park-context.sh`,
`token-unpark-context.sh`) rather than inline in the command. The permission check statically
analyses an inline command string, and a command substitution, variable assignment or
conditional in it fails to parse and surfaces as a *permission* error rather than a syntax one —
which sends you to `allowed-tools`, where the problem is not. One plain invocation in the
command file; all the shell grammar in the script.

---

## Environment variables

### Budgets and thresholds — `token-cycles.sh`

| var | default | means |
|---|---|---|
| `TOKEN_BUDGET` | tier | output budget for the table |
| `TOKEN_ALERT_BUDGET` | 20000 | output budget the hook alerts on |
| `TOKEN_GROWTH_BUDGET` | 25000 | growth budget |
| `TOKEN_ALERT_GROWTH` | — | growth budget the hook alerts on |
| `TOKEN_RESTART_THRESHOLD` | — | context at which a restart is advised |
| `TOKEN_CONTEXT_WARN` / `TOKEN_CONTEXT_HIGH` | — | the two context bars |

### The pane — `token-sessions.sh`

| var | default | means |
|---|---|---|
| `TOKEN_CACHE_TTL_MIN` | 60 | prompt-cache TTL in minutes |
| `TOKEN_REQ_PER_CYCLE` | 2.3 | requests per cycle, for the modelled cache reads |
| `TOKEN_PRICE_IN` | 5 | $/MTok input; everything else is a multiple of it |
| `TOKEN_CTX_FULL_K` | 300 | context bar full scale, thousands |
| `TOKEN_CLOSED_MAX` | 12 | closed sessions listed by `--all` |
| `TOKEN_NICK_VARIANTS` | 6 | re-rolls before `n` returns to the default name |
| `TOKEN_PARK_STALE` | 15 | minutes of work after a `/park` before its checkpoint counts as behind |
| `TOKEN_BELL` | 1 | `0` silences the lapse bell for good |
| `TOKEN_BELL_MIN` | 5 | minutes of cache life left that rings it |
| `TOKEN_POPUP` | 1 | `0` silences the desktop notification |
| `TOKEN_SHOW_OLLAMA` | 0 | `1` puts local-runtime rows back in the pane |
| `TOKEN_FILTER` | — | start filtered |
| `TOKEN_PLAN_WEEK_USD` | 0 | plan ceiling per week; unset means no percentage |
| `TOKEN_PLAN_5H_USD` | 0 | plan ceiling per 5-hour window |

---

## Data files

All under `~/.claude/`. **None are shipped in this repo** — they are personal, machine-specific,
and gitignored.

| file | written by | holds |
|---|---|---|
| `token-history.csv` | Stop hook | one raw row per cycle. **The dataset.** |
| `token-titles.tsv` | the pane | sid → title cache; a first turn never changes, so it is extracted once |
| `token-meta.tsv` | the pane | sid → mtime, last activity, cwd |
| `token-nicks.tsv` | the pane | sid → re-roll variant, and any name typed with `/n` |
| `token-projmap.tsv` | the pane | short sid → project label, for the analytics tab |
| `token-occupancy.state` | `token-cycles.sh` | context occupancy between runs |
| `token-gap-warn.log` | the gap hook | one row per firing, and which case it was |
| `token-alert-errors.log` | Stop hook | the hook's own failures, so it cannot die silently |
| `checkpoints/<proj>.<topic>.md` | `/park` | resume checkpoints, one per topic |

Read but never written by these tools:

| file | written by | holds |
|---|---|---|
| `sessions/<pid>.json` | the CLI | pid → sessionId, cwd, name |
| `projects/*/<sid>.jsonl` | the CLI | the transcript |

---

## Two things the disk read gets wrong if written the obvious way

Both were found the expensive way. Know them before editing `token-sessions.sh`.

**A transcript's mtime is not its last activity.** Resuming a session touches the file without
adding a record, so a window the IDE reopened at startup reports cache life it does not have —
measured here at 319 and 877 minutes of phantom warmth. Read the last record's `timestamp`
instead, and compare against `now` through `mktime` on *both* sides so the zone offset cancels.

**A pid does not identify a session.** Windows recycles pids and `sessions/<pid>.json` outlives
its process, so opening a new IDE project can hand a dead session's pid to something unrelated
and light it up as live. Check the command line too — but run `ps` as `COLUMNS=1000 ps -W`,
because `ps` truncates every line to terminal width and the Claude binary path is ~105
characters, so in a normal window the match target is cut clean off and live sessions vanish
from the list entirely.

## Two things that will bite you editing the renderers

**`LC_ALL=C` is pinned at the top and is not a stylistic choice.** In the C locale awk's
`length()`/`substr()`/`index()` count **bytes**; in a UTF-8 locale they count characters. Every
column is padded by hand around three-byte glyphs on the byte assumption. Worse, the bracket
range over high bytes that finds UTF-8 continuation bytes is a *collation* range — gawk under a
UTF-8 locale rejects it outright, fatally, on the first frame. An interactive shell often
carries no `LANG`, so the pane works; the desktop shortcut runs a **login** shell, the profile
sets one, and the program dies before painting anything.

**No apostrophes inside the awk programs — in comments as readily as in strings.** The renderers
are single-quoted awk, so one apostrophe closes the quote and hands the rest to bash. It fails
as a shell syntax error hundreds of lines from the cause. This is why every comment in there
says "the panel" and not "the panel's". `bash -n token-sessions.sh` catches it instantly;
nothing else will.
