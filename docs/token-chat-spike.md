# token-chat: headless protocol spike (2026-10-01, CLI 2.1.286)

Design basis for `windows/token-chat/`, a native WPF front end over a hidden `claude -p`.
Driver: `windows/token-chat/spike/spike.js <profile>`. Raw recordings `*.raw.jsonl` sit beside
it, git-ignored: the `initialize` response carries the account email and every event carries
local paths. Scrub them before any become test fixtures.

## Launch

Spawn `node_modules/@anthropic-ai/claude-code/bin/claude.exe` directly, not the npm `claude.cmd`
shim, so arguments and kill go to the real process.

```
-p --input-format stream-json --output-format stream-json --verbose
   --include-partial-messages --include-hook-events
   --permission-prompts host --permission-prompt-tool stdio   (hidden flag, not in --help)
```

Then send `{"type":"control_request","request_id":"init1","request":{"subtype":"initialize","hooks":null}}`
**before the first user message**. Without the handshake:

- every permission prompt is auto-denied (`system:permission_denied`), even inside `--add-dir`
- AskUserQuestion is missing from the tool list, even when named in `--tools`
- turn 2 rewrote the message tier (~15k full, ~9k lite). It did not happen with the handshake.
  Likely cause: commands load late (`system:commands_changed`). One sample each. The live smoke
  (`spike/smoke.cs`) confirmed it with the handshake: turn 2 wrote only 566 tokens.

The `initialize` response returns `commands`, `agents`, `models` (with `supportedEffortLevels`),
output styles, `account.subscriptionType`, `pid` and `current_permission_mode`.

## Messages

- User: `{"type":"user","message":{"role":"user","content":<string | blocks>},"parent_tool_use_id":null}`.
  An image block (`source.type: base64`) works.
- Permission: `control_request` with `request.subtype: can_use_tool`, `tool_name`, `input`,
  `description`, `permission_suggestions` (e.g. `setMode acceptEdits`, destination `session`)
  and `tool_use_id`. Reply with `{"type":"control_response","response":{"subtype":"success","request_id":<id>,
  "response":{"behavior":"allow","updatedInput":<input>}}}`, or `behavior:"deny","message":...`.
- AskUserQuestion arrives as `can_use_tool` with `requires_user_interaction`. Answer by allowing
  with `updatedInput = {...input, answers: {<question>: <label>}}`.
- Interrupt: `control_request` `{subtype:"interrupt"}` → `control_response {still_queued:[]}`,
  and then a `result` with `subtype:error_during_execution`.
- `/compact` works: `system:compact_boundary`, then the SessionStart:compact hooks fire.
  `/context` works and is local (0 tokens), except under `--disable-slash-commands`.
- `rate_limit_event.rate_limit_info.unifiedWindows.{five_hour,seven_day}.utilization`: live
  subscription headroom.
- Also seen: `system:{hook_started,hook_response,status,thinking_tokens,informational}`,
  `stream_event` (Anthropic SSE events), `assistant` (repeated per content block, same usage), `result`.
- Usage: `assistant` repeats the `message_start` usage, so its `output_tokens` is stale (7 vs a
  final 196). The final count is only in `stream_event` `message_delta`. `result.usage` is the sum
  over the turn's requests (the M1 ledger reproduces it exactly) and is all zeros after an interrupt,
  although the interrupted request was billed.

## Fixed context (first request, in + cache write + cache read)

| profile | flags | tokens |
|---|---|---:|
| interactive terminal | — | 46.2k here, ~60k Unity (first request in each transcript) |
| headless full | defaults | 30.3k–31.5k |
| lite | `--tools Read,Edit,Write,Bash,Grep,Glob --strict-mcp-config` | 15.7k |
| lite + AskUserQuestion (token-chat `Profile.Lite`) | same, tool added | 16.9k (live smoke) |
| lite, no skills | + `--disable-slash-commands` | 15.3k |
| slim | + `--system-prompt <one line>` | 12.9k |

`/context` for headless full: system prompt 2.3k, tools 9.6k, MCP 1.4k, memory files 7.5k
(the global CLAUDE.md alone is 7.2k), skills 3.6k. That sums to 24.4k; the rest of the 31.5k is
hook output and environment. The slim profile saves only 2.3k over lite and drops Claude Code's
behaviour prompt, so it is not worth it. A 15.5k system-plus-tools prefix stayed cached across
separate processes.

Not recorded: the image test and the first `/context` for full (an overwritten run).
