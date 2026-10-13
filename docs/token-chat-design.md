# token-chat: design and build plan (2026-10-01)

A native Windows chat that replaces the terminal for Claude Code sessions. It drives a hidden
headless `claude.exe` over stream-json. The protocol facts are in `token-chat-spike.md`.

## Decided

- **Wrapper, not a direct API client.** The subscription (Claude Pro) covers it, and hooks,
  skills, tools and compaction come with the CLI. The direct API would bill every token.
- **C# WPF on .NET 10, fully native.** No WebView, no HTML. It lives in `windows/token-chat/`.
- **Default profile: full.** Lite (`--tools Read,Edit,Write,Bash,Grep,Glob,AskUserQuestion --strict-mcp-config`, 16.9k)
  is a per-tab option. Slim is not offered.
- **A session belongs to one front end.** Headless mode warms its own prefix, so the app only
  resumes sessions it started.
- **A tab is a chain of sessions.** Handoff, `/clear` and `/compact` start a new segment in the
  same tab. Earlier segments collapse into a section headed by the checkpoint's
  Goal / Decided / Next, and can be expanded to read.

## Why the floor is smaller (measured, same repo)

| | first request | cached system+tools prefix |
|---|---:|---:|
| terminal | 46.2k | 28.6–30.4k |
| headless full | 30.3–31.5k | 15.5k |

The per-project part (CLAUDE.md, memory, skills, hooks, environment) is about 16–17k in both.
The whole difference is the static prefix: the terminal sends tool definitions and system-prompt
sections for interactive-only features (Artifact, AskUserQuestion, feedback, terminal guidance).
The terminal's size in the Unity project is ~60k. Unity `/unpark` sessions start at 85–88k,
so about 25k is the unpark payload; that is the dominant handoff cost there.

## Auto-handoff

The app knows the session's floor F (its first request) and the checkpoint cost R (its unpark
request minus F), so it computes the bar per session instead of using a constant:

```
restart = 2(F + R) + P          P = park cost, ~23k warm
carry   = (ctx − F − R) × 5.8 × 0.1 per cycle
bar     = F + R + restart / (N × 0.58)      N = 3 (median cycles remaining)
```

Headless full here: F 31k, R ~5k → bar ≈ 90k. Terminal here: ≈ 120k. Unity with its 25k unpark:
much higher. Measure R before trusting it.

Flow, with no interruption:

1. **Trigger** only at a clean point: a `result` has arrived, no permission or question is
   pending, and ctx ≥ bar.
2. **Park immediately** in the old session, in the background while the user reads, with the
   cache still warm. A slim bar says "next message starts fresh".
3. **Start the new session** (`--resume` none, first message `/unpark <topic>`). It starts when
   the user begins typing (pre-warm) or on send (lazy). The user's message goes in queued
   behind the unpark.
4. **Collapse** the old segment. "Continue in old session" stays available while the old
   process's cache is warm; after that the process is killed.

Modes per tab: auto / ask (one-click bar) / off. **Default: ask.** **Pre-warm on typing: yes.**
The 300k hard block in `token-block.sh` never comes into play.

## Integration with the existing tooling

- Child env `TOKEN_CHAT=1` plus a tab id, so hooks can tell they run under the app. For
  example, `token-block.sh` returns a decision the app renders as a dialog instead of using
  the clipboard path.
- Registry `~/.claude/token-chat/sessions.json` (tab → sid chain, pid, profile, boundaries) for
  `token-sessions.sh` and the widget.
- `bin/token-cycles.sh:863` drops `sdk-cli` sessions as probes. It has to keep app sessions
  (match by registry sid or by env marker).
- Cache renewal is a stdin message on the app's timer. `ClaudeTokenPokeDue` should skip app
  sessions.
- The widget gets a Chat button.

## Milestones (one implementation session each, roughly)

1. **Core** `TokenChat.Core`: resolve and spawn `claude.exe`, handshake, typed events,
   send / interrupt / answer permission / answer question. Usage accounting deduplicates the
   repeated `assistant` events by message id. Rate-limit info. Tests replay **scrubbed**
   fixtures, so a scrub script (email, user paths) comes first.
2. **Window**: tabs, a virtualized transcript, markdown (MdXaml verified 2026-10-01: rows size
   to content, 10 Hz re-render smooth), streaming deltas throttled to about 10 Hz, input box.
   Styled as the token-sessions widget (`Theme.xaml`); code blocks are AvalonEdit editors whose
   named colours are lifted for the dark card at startup.
3. **Interaction**: permission cards with an Edit/Write diff preview and "allow for session";
   AskUserQuestion and `▶` blocks as buttons; Stop; message queue; attachments (drag, paste;
   image and document blocks with a token estimate before send).
4. **Token integration**: header (ctx, cache clock, heat, five-hour and seven-day use), renewal
   timer, idle auto-park, registry, hook awareness, `token-cycles.sh` change.
5. **Session chain**: manual and auto handoff, compact and clear boundaries, resume app sessions
   from the transcript jsonl, profiles.
6. **Ship**: `dotnet publish` in `install.sh`, widget button, toasts, hotkey and tray, search.

## Sidebar: the widget moves into the app (decided 2026-10-04)

- **The sidebar replaces the tabs.** A tab carried title, state dot and project colour; a row carries
  those and the stats. `+` and `lite` move to the sidebar header; the caption keeps the window glyphs.
- **Every session is listed**, the app's first, terminal ones grouped below. A terminal row has stats and
  controls; opening it focuses its window through `token-open.ps1` (a session belongs to one front end).
- **The footer's widget row goes.** It is the selected sidebar row twice. Its effort menu moves to the
  footer's status line.
- **Row, ~280px:** line 1 dot, name, verdict, ctx (live for app sessions), cache clock; line 2 growth,
  heat, marks, blocked. The selected row expands to spend and grades (the widget's `d`).
- **Controls** through `token-sessions.sh --extend <short> N` / `--unblock <sid>` / `--name <sid> <name>`,
  plus copy resume, open folder, park/close for app sessions. On-row buttons for `+`/`-` mark and lift-block
  (the most used keys in `token-keys.log`: e 84, enter 31, u 11), the rest in a context menu; the widget's
  letters while the sidebar has focus. The snapshot is patched on the click, the next collect confirms.
- **The widget becomes optional.** When the feed is over ~75s old, the app runs `--json` itself and swaps
  the file in as `Save-Feed` does. It must also do the widget's `Ensure-PokeDue` (not yet read).

Phases, one session each:

1. Read-only sidebar beside the tabs: `FooterRow` generalised to `SessionRow`, `SidebarView` on `SessionFeed`.
2. Controls: `SessionControl` in Core, mark clamp (floor = spent, cap = `ext_max`) with tests.
3. Tabs out: the sidebar navigates; footer row out, effort menu moved.
4. Collector, plus limits (five-hour, seven-day), day spend and account in the sidebar header.
5. Parked section: checkpoints below the sessions; opening one starts a session on `/unpark <topic>`.
