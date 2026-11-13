# Level 2 — measure (status line + history)

**What it adds:** a status line showing context size, minutes of cache left and the advice
that follows from the two. Each prompt also gets one row in `~/.claude/token-history.csv`, and
you get `/tokens` and `--stats` to read your own numbers. No model tokens are spent: everything
is read from disk.

**Needs:** Claude Code run at least once, bash 4+ and awk, node. On Windows that means Git
Bash.

## Install

1. Get the `claude-token-tools` repo, then run:
   ```sh
   cd claude-token-tools
   ./install.sh            # --dry-run first to see what it touches; --link to symlink
   ```
   This copies the scripts into `~/.claude/` and the slash commands into
   `~/.claude/commands/`. Anything it would overwrite is backed up first.
2. Merge these keys into `~/.claude/settings.json`, keeping your existing keys:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash \"$HOME/.claude/token-cycles.sh\" --status"
     },
     "hooks": {
       "Stop": [
         { "hooks": [ { "type": "command", "shell": "bash", "timeout": 10,
             "command": "bash \"$HOME/.claude/token-cycles.sh\" --alert" } ] }
       ]
     }
   }
   ```
   **The `Stop` hook is the data collector. Nothing else works without it.**
3. Restart Claude Code.

## Use

- **Status line:** the `cache NNm` field is the whole park/clear decision. `COLD` means the next
  message rewrites the window.
- **`/tokens`:** cost per prompt for this session.
- **`~/.claude/token-cycles.sh --stats`, after a week:** shows your cold floor, hit rate, cost
  split, the restart break-even and the prompts that went over budget. **Re-tune the Level 1
  numbers from this**, especially if you mostly use Fable.

## Verify

1. Send one prompt in a new session.
2. Check that the last row of `~/.claude/token-history.csv` has the current time.
3. Check that the status line shows a context figure and `cache 59m` or so.
