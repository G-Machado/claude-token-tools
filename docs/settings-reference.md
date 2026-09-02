# settings.json reference

Condensed from the `/update-config` skill, which is bundled in the CLI and dumps a ~600-line
schema on every invocation. This file covers the cases that actually come up. If a task needs
something not here, **ask the user to run `/update-config`** — it is set to user-invocable-only
so it no longer loads itself into context unasked.

## Files and precedence

`~/.claude/settings.json` (global) → `.claude/settings.json` (project, committed) →
`.claude/settings.local.json` (project, gitignored). Later overrides earlier.

**Always read before writing, and merge — never replace arrays.** A malformed settings.json
silently disables every setting in that file.

## Hooks

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "...", "timeout": 10 }
        ]
      }
    ]
  }
}
```

- `matcher` is a tool-name pattern; omit it for events that aren't tool-scoped (`Stop`,
  `SessionStart`, `UserPromptSubmit`, `PreCompact`).
- Events: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `UserPromptSubmit`,
  `SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`, `PreCompact`, `PostCompact`,
  `PermissionRequest`, `FileChanged`. (Longer list exists; these are the usable ones.)
- Hook types: `command`, `prompt` (LLM check), `agent`, `http`, `mcp_tool`. `prompt`/`agent`
  are tool-events only.
- Useful command fields: `shell` (`bash`|`powershell` — set it explicitly on Windows),
  `timeout` (seconds), `async`, `once`, `if` (permission-rule filter so the hook doesn't even
  spawn on non-matching calls), `statusMessage`.

**Hook I/O.** The payload arrives as JSON on **stdin** — `session_id`, `transcript_path`, `cwd`,
`hook_event_name`, plus `tool_name`/`tool_input`/`tool_response` on tool events. On Windows,
paths in it are JSON-escaped (`C:\\Users\\...`); `tr '\\' '/'` is enough for Git Bash.

Output JSON controls behavior:
- `systemMessage` — shows a line to the **user**; the clean way to alert without touching my context.
- `hookSpecificOutput.additionalContext` — injects text into **my** context.
- `continue: false` + `stopReason` — blocks.
- `suppressOutput: true` — hides stdout from the transcript.

**The watcher gotcha:** a newly added hook only takes effect if the settings file's directory
already had a settings file when the session started. Otherwise the user must open `/hooks` once
or restart. I cannot do that myself — `/hooks` is a user-facing menu.

Hooks fire outside the current turn for `Stop`/`SessionStart`/`UserPromptSubmit`, so they can't
be proven working in-turn. Pipe-test the command instead: `echo '{...}' | <command>`.

## Permissions

```json
{ "permissions": { "allow": ["Bash(git *)", "Read"], "deny": [], "ask": [],
                   "defaultMode": "default|plan|acceptEdits|dontAsk|auto|bypassPermissions" } }
```

Exact match `Bash(npm run test)`, prefix wildcard `Bash(git *)`, or tool-only `Read`.

## Other keys worth knowing

- `skillOverrides`: `{ "<skill>": "on" | "name-only" | "user-invocable-only" | "off" }` —
  `user-invocable-only` hides a skill from me but keeps `/name` working for the user. This is the
  lever for token-heavy skills.
- `env`: `{ "VAR": "value" }`
- `model`, `effortLevel` (`low|medium|high|xhigh`), `fastMode`, `alwaysThinkingEnabled`
- `attribution`: `{ "commit": "", "pr": "" }` — empty string hides attribution
- `statusLine`: `{ "type": "command", "command": "..." }`
- `autoCompactEnabled`, `autoCompactWindow` (100k–1M)
- `disableAllHooks` — kill switch if a hook misbehaves

Simple prefs (`theme`, `editorMode`, `verbose`, `model`) are better set via `/config` than by
hand-editing.
