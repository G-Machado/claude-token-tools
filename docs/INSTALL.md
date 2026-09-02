# Install

## 0. Requirements

- **Claude Code**, run at least once — the tools read what the CLI writes to `~/.claude/`,
  so that directory has to exist and have something in it.
- **bash 4+ and awk.** On Windows this means Git Bash (bundled with Git for Windows).
  Linux and macOS already have both; on macOS the bundled bash is 3.2, so
  `brew install bash gawk` if the pane misbehaves.
- Optional: **mintty** for the styled desktop window, and `clip.exe` / `pbcopy` / `xclip`
  for the `y` key. Both degrade quietly when missing.

Nothing here talks to the network or to the API. Every number comes off disk.

## 1. Run the installer

```sh
git clone <this repo> claude-token-tools
cd claude-token-tools
./install.sh
```

It copies `bin/*.sh` into `~/.claude/`, the slash commands into `~/.claude/commands/`, and
backs up anything it would overwrite as `<name>.bak-<timestamp>`.

| flag | effect |
|---|---|
| `--link` | symlink instead of copy, so edits in the repo are live |
| `--no-cmds` | skip `/park`, `/tokens`, `/unpark` |
| `--dry-run` | print what would happen, change nothing |

The scripts address each other by absolute path (`$HOME/.claude/...`), which is why they have
to be installed rather than run out of the clone. `--link` is the way to develop against them.

## 2. Wire up the hooks and the status line

This is the one manual step — `install.sh` prints it too. Merge into
`~/.claude/settings.json`, keeping any keys you already have:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/token-cycles.sh\" --status"
  },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "shell": "bash", "timeout": 10,
          "command": "bash \"$HOME/.claude/token-gap-warn.sh\"" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "shell": "bash", "timeout": 10,
          "command": "bash \"$HOME/.claude/token-cycles.sh\" --alert" } ] }
    ]
  }
}
```

What each one does:

- **`statusLine`** — prices the session you are typing in: context, cache life, and the advice
  that follows from the pair.
- **`Stop` hook** — fires when a cycle ends. Warns on a budget breach, and appends one raw row
  to `token-history.csv`. **This is the data collector — nothing else works without it.**
- **`UserPromptSubmit` hook** — fires before a prompt is sent. Silent unless you have just
  resumed a large session after an idle gap.

Restart Claude Code. Both hooks run every cycle anyway, so collecting the history costs no
model tokens; only *reading* it does, and reading is something you do, not something the model does.

## 3. Verify

```sh
bash ~/.claude/token-cycles.sh              # this session, cycle by cycle
bash ~/.claude/token-sessions.sh            # one snapshot of every session
bash ~/.claude/token-sessions.sh --watch    # the live pane
```

After a few Claude Code cycles, `~/.claude/token-history.csv` should be growing. If it is not,
the Stop hook is not firing — check `~/.claude/token-alert-errors.log`, which is where the hook
records its own failures rather than dying silently.

The views are honest but thin until roughly **20 cycles** are on disk, and the grades and the
retune sweep want **40+**. Give it a day of normal use before judging any number.

## 4. Optional: the desktop window

`bin/token-sessions-launch.sh` is the entry point for a shortcut, so the flags live in a text
file rather than in shortcut properties. `config/token-sessions.minttyrc` styles the window.

On Windows, make a shortcut to:

```
"C:\Program Files\Git\usr\bin\mintty.exe" -c "%USERPROFILE%\.claude\token-sessions.minttyrc" /bin/bash -l "%USERPROFILE%\.claude\token-sessions-launch.sh"
```

Edit the launch script to change the default view (`--watch`, `--browse`, `--analytics`,
`--compact`, `--all`, or a refresh interval in seconds). No need to touch the shortcut again.

## 5. Optional: calibrate the plan percentages

The analytics tab can report spend as a percentage of your plan, but nothing on disk records
what the plan is — `/usage` fetches it from the API. So it is calibrated once, by hand:

```sh
export TOKEN_PLAN_WEEK_USD=250   # $ of API-equivalent spend per week
export TOKEN_PLAN_5H_USD=20      # $ per 5-hour window
```

Put those in `token-sessions-launch.sh` so they survive an update. Run `/usage` in Claude Code,
read the percentage it reports, and set the ceilings so the two agree. Left unset, the tab
reports spend without inventing a limit.

## 6. Optional: adopt the policy

The tools measure; `docs/COST-MODEL.md` is the policy they measure *against* — the park/clear
thresholds, the budget tiers, and where each number came from. Copy the parts you want into
your own `~/.claude/CLAUDE.md` so the model follows the same rules the hooks enforce.

## Uninstall

```sh
./uninstall.sh
```

Removes the scripts and slash commands, keeps your data (`token-history.csv`, `token-titles.tsv`,
`checkpoints/`), and reminds you to drop the hooks from `settings.json` by hand.

## Troubleshooting

| symptom | cause |
|---|---|
| pane dies instantly with `Invalid collation character` | a UTF-8 `LANG` reached the awk renderer. The script pins `LC_ALL=C` at the top; if you edited that line, put it back — every column is padded on the byte assumption. |
| columns misaligned by a few characters | same cause, milder: `length()` counts characters instead of bytes. |
| a shell syntax error hundreds of lines from anything you touched | an apostrophe inside a single-quoted awk program — in a comment counts. `bash -n token-sessions.sh` finds it instantly; nothing else will. |
| every session shows a full hour of cache life | a transcript mtime was trusted instead of its last record timestamp. Resuming touches the file without adding a record. |
| a dead session shows as live | pids are recycled and `sessions/<pid>.json` outlives its process. The script also matches the command line; on Windows that needs `COLUMNS=1000 ps -W`, because `ps` truncates to terminal width and the Claude binary path is ~105 characters. |
| history stops growing | the Stop hook is not firing. `~/.claude/token-alert-errors.log`. |
