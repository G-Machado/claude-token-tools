# claude-token-kit — read this before installing anything

A small set of habits, a `CLAUDE.md` policy, and optional local scripts for spending fewer
tokens in Claude Code without getting worse results. This page covers four things: what it is
for, what each level changes on your machine, what it never does, and how to take it back out.

## Quick start (Windows)

1. Double-click **`start-claude.exe`**.
   - It opens Claude Code in this folder and types a prompt asking Claude to explain the kit and
     help you choose a level.
   - It does **not** send the prompt.
2. Read the prompt, then press **Enter**.
   - The prompt asks Claude to install nothing until you say so.

Good to know:

- **Editing the prompt.** Edit `start-claude.txt`; it is used instead of the built-in text.
- **SmartScreen warning.** The exe is unsigned, so Windows may show "Windows protected your PC".
  Click *More info*, then *Run anyway*.
- **Building it yourself.** The source is in `launcher-source/` (one C# file); `build.cmd` builds
  it with the compiler that ships with Windows.
- **What it does:** starts `claude` in a new console, waits until the input box is on screen
  (never while a trust or setup dialog is open), and types the prompt as keystrokes. If that
  fails, the prompt goes to your clipboard and a message box says so. Log:
  `%TEMP%\start-claude.log`.

No Windows? Run `claude` in this folder and paste the text from `start-claude.txt`.

## What changed in this version (2026-11-12)

The numbers were re-checked against the official price page and measured against real use.
What matters to you:

- **Prices are current.** Opus 5.5 is $4 in / $20 out per million tokens, and Fable 5.2 is $8 / $40.
  Cache reads cost $0.20 on both, which is 0.05× of input on Opus and 0.025× on Fable. On Fable,
  output and cache rewrites are the cost to watch; a long, warm session is cheap on both.
- **Clear a cold window at ~97k, not ~68k.** A resume note (`/park`) does not make the next
  session cheaper to restart: getting back to work costs ~34k either way. What the note buys is
  resuming the right task. The cold-window block now fires at 97k as well.
- **The 500-line read guard also covers `cat`.** Claude often reads files through the shell,
  and the guard used to miss those reads.
- **Guards that measurably help:** the "stop at a clean point" nudge (prompts over 30k output
  fell by half). The cold-window block was overridden 7 times in 10 at the old bar, which is
  why the bar rose.

## What it is for

Claude Code bills the whole conversation window again on every request: about 5 re-reads per
prompt. The cache that makes those re-reads cheap lives only one hour. Most avoidable spend
comes from three habits:

- reading too much into the window
- leaving a big window idle past the hour and then typing into it, so it is rewritten at 2×
- packing investigation, design and implementation into one prompt

The kit addresses those three, in this order of priority: **tokens › correctness of claims ›
content delivered › hand-off-ability › rework › your attention › time**. It never trades away
verification before anything irreversible (commit, push, delete, overwrite).

It was built and measured by one developer over about two months, mostly on Opus. The numbers
are starting points: re-tune them from your own data after a week (Level 2).

## Choose how far to go

Each level is opt-in, and each assumes the ones below it. Details: [docs/workflow-kit/README.md](docs/workflow-kit/README.md).

| level | changes on your machine | can it stop you from doing something? |
|---|---|---|
| 0 — habits | nothing | no |
| 1 — policy | a block **you** paste into `~/.claude/CLAUDE.md`. It changes how the model behaves: it suggests splits, reads files more cheaply, labels claims, suggests fresh sessions | no; it only advises |
| 2 — measure | scripts copied into `~/.claude/`, a status line, one `Stop` hook | no |
| 3 — guards | more hooks, plus the `/park` `/unpark` `/handoff` `/arc` `/tokens` commands | **yes**, see below |

## What the scripts do (Levels 2–3)

**Install.** `./install.sh` copies scripts into `~/.claude/` and slash commands into
`~/.claude/commands/`. Anything it would overwrite is first backed up as
`<name>.bak-<timestamp>`. On Windows it adds a "Claude Widget" desktop shortcut.

- It **does not edit your `settings.json`**. It prints the hooks and you paste the ones you want.
- That printed block also suggests a `permissions.deny` list (`~/.ssh`, `~/.aws`, `.env`,
  `*.pem`, Claude credentials). It is optional, but recommended.
- `./install.sh --dry-run` shows everything it would do and changes nothing.

**Reads, all local:**

- Claude Code's own files under `~/.claude/`: session transcripts, `sessions/*.json`,
  `history.jsonl`, and the status-line usage data.
- That is how it knows context size, cache age and cost.

**Writes, all local, all under `~/.claude/`:**

- `token-history.csv`: one row per prompt
- `checkpoints/`: your `/park` notes
- a few small logs and state files (`token-*.log`, `token-*.tsv`, `token-snapshot.json`,
  `token-scorecard.csv`)
- a `token-blocks/` folder, created only after something has been blocked

**Adds to the model's context:**

- a one-line `[widget]` summary per prompt
- an occasional nudge ("stop at a clean point", "this window went cold")
- after a compaction, the re-injected checkpoint

Each is tens of tokens; together they cost far less than they save.

**Network.** None. The original tools check GitHub once a day for a new version; that check is
switched off in this copy. To turn it on, set `TOKEN_UPDATE_REPO=<owner>/<repo>`. It then reads
one `VERSION` file a day and sends nothing about you.

**Can stop you (Level 3 only, each hook opt-in):**

- `token-block.sh` refuses a prompt in two cases:
  - **above 300k context**: only `/park` `/compact` `/clear` `/exit` pass
  - typed into a **cold window above 97k**: your text goes to the clipboard, and
    `bash ~/.claude/token-sessions.sh --unblock` or the widget's `u` lets it through
  - `TOKEN_COLD_BLOCK=0` and `TOKEN_MAX_BLOCK=<n>` adjust these
- `token-readguard.js` refuses a whole-file read of more than 500 lines **once**, by Read or by a
  bare `cat` in the shell. The same read
  retried passes, so it costs one round trip, not the read. Turn it off with `TOKEN_READ_GUARD=0`.

## What it never does

- **No telemetry.** Nothing is collected about you or sent anywhere.
- **No calls to the Claude API**, and it never spends tokens by itself. Every number comes off
  disk.
- **No typing into your sessions unless you ask.** `token-sessions.sh --poke-due` (Windows) can
  send a session its own renewal or `/park` message. It runs **only** when you run it; the kit
  ships no scheduler for it.
- **No account access.** It reads usage that Claude Code already writes; it never touches
  credentials.
- **No git operations on your projects.** The only git command in the kit is a `git pull` of the
  kit's own folder, and only when you ask it to update.

## Taking it back out

1. Run `./uninstall.sh` (`--dry-run` first if you like). This removes the scripts, the commands
   and the shortcut.
2. Delete the hook entries you added to `~/.claude/settings.json`.
3. Remove the block you pasted into `~/.claude/CLAUDE.md`.

Your data (`token-history.csv`, `checkpoints/`, titles) is kept; delete it by hand if you want
it gone.

## Good to know

- **Platforms.** It is written for Git Bash on Windows, where it is tested. The bash side should
  run on Linux and macOS (bash 4+, awk, node). The widget and `/handoff`'s new-window launch are
  Windows-only.
- **Extracted from a larger personal toolset.** Some code paths mention tools that aren't
  included: TokenChat (a desktop chat app), cswap (multi-account switching) and the master/
  delegate commands. Those paths stay inactive without the tools.
- **Using Fable and Opus:** see the "Using Fable and Opus together" section of
  [docs/workflow-kit/README.md](docs/workflow-kit/README.md). In short: pick the model per
  session and never switch mid-session.
- **Licence:** MIT, see `LICENSE`.
- **Background:** [docs/WORKFLOW.md](docs/WORKFLOW.md) has the reasoning and numbers;
  [docs/COST-MODEL.md](docs/COST-MODEL.md) has the derivations.
