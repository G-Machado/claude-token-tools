#!/usr/bin/env bash
# UserPromptSubmit hook: the input block.
#
# WHAT IT IS FOR
#
# A window that has spent every extension mark has no budgeted way left to cross
# the hour. The read that would carry it is cheap - it is always cheap, roughly
# 20x cheaper than the rewrite - and that is precisely the problem: cost never
# says stop, so a session carried on cheap reads can run all day and the only
# thing that ends it is a lapse nobody chose. The marks are the budget for that,
# and this hook is what makes the budget mean something. When the last one is
# spent the window stops taking ordinary work until it has been checkpointed.
#
# WHY IT BLOCKS PROMPTS, AND NOT KEYSTROKES
#
# "Block the input" invites a keyboard hook or a disabled console window, and
# both are the wrong shape: they can strand you locked out of your own terminal
# if the thing holding the hook dies. Here the prompt has been composed and
# submitted, this hook sees it whole, and the refusal is a property of the text
# rather than of the keyboard - which also means the window itself never stops
# responding, so nothing can wedge it.
#
# WHY NOTHING GETS THROUGH, AND WHY THE WIDGET HOLDS THE KEY
#
# Until 2026-09-10 slash commands passed and /park lifted the block, on the
# reasoning that the escape hatch should be the thing you were being told to do.
# The auto-park removed that reason: by the time this arms, the sweep has already
# typed /park into the window and the checkpoint is on disk, so there is nothing
# left for the session to do that would earn its release. What remains is a
# window that should be cleared, and every keystroke spent deciding otherwise is
# charged against a prefix that is about to lapse anyway.
#
# So the block is total - ordinary prompts, /park, /clear, /help, all of it - and
# the only key is `u` in the token widget (or --unblock from any shell). That is
# deliberate friction and not a lockout: the widget is already open, it is the
# thing that told you the window ran out of marks, and lifting from there is one
# keypress in the place where the decision is actually visible.
#
# CUT, NOT DISCARD
#
# A blocked prompt is text that was typed and will not be sent, so it must not
# simply vanish. Before refusing, the prompt goes to the clipboard and to a file
# under token-cut/. The clipboard is the ergonomic half - the block reads
# as a cut, and paste puts it back in the fresh window after /clear. The file is
# the honest half, because a clipboard is one keystroke from being overwritten
# and this is the only copy of something a person wrote.
#
# THE FAST PATH IS THE POINT
#
# This runs on EVERY prompt in EVERY session, and it does nothing in almost all
# of them. So the first line is a directory test - the block directory does not
# exist until something has been blocked once - and the second is a file test.
# Nothing is parsed, spawned or read until both say there is work to do.

BD="${TOKEN_BLOCK_DIR:-$HOME/.claude/token-blocks}"
# Cut prompts live in a directory of their own, and that is not tidiness. The
# fast path below is "does the block directory exist", so anything else kept in
# there would hold it open forever and every prompt on this machine would start
# paying a JSON parse to learn it was not blocked. Markers in one, the text
# people wrote in the other, and the first can be emptied and removed.
CD="${TOKEN_CUT_DIR:-$HOME/.claude/token-cut}"

# One stat, and the answer for the overwhelming majority of prompts ever
# submitted on this machine. Created lazily by --block, removed when empty.
[ -d "$BD" ] || exit 0

payload=$(cat)
[ -n "$payload" ] || exit 0

# session_id and prompt out of the payload without a JSON parser. The prompt is
# the only field here that can contain arbitrary text - quotes, newlines encoded
# as \n, braces - so it is taken last and taken whole, and never used to build
# another command line.
sid=$(printf '%s' "$payload" |
      sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$sid" ] || exit 0
[ -f "$BD/$sid" ] || exit 0

# The reason this session was armed, written by --block. Kept short; it is
# repeated back to the user on every refusal, so it has to read well the fifth
# time as well as the first.
why=$(head -1 "$BD/$sid" 2>/dev/null)
[ -n "$why" ] || why="this window is out of extension marks"

# The prompt, decoded far enough to be recognisable. Only the escapes that
# change what the FIRST character is matter for the filter, and for the saved
# copy the common four are worth undoing so the file reads like what was typed.
prompt=$(printf '%s' "$payload" | awk '
  function dec(s,   i, ch, nx, out) {
    for (i = 1; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (ch == "\\") { nx = substr(s, i + 1, 1); i++
        if (nx == "n") out = out "\n"
        else if (nx == "t") out = out "\t"
        else if (nx == "\"") out = out "\""
        else if (nx == "\\") out = out "\\"
        else if (nx == "u") { i += 4; out = out "?" }
        else out = out nx
        continue }
      if (ch == "\"") break
      out = out ch }
    return out }
  { if (match($0, /"prompt"[[:space:]]*:[[:space:]]*"/)) {
      print dec(substr($0, RSTART + RLENGTH)) } }')

# No filter any more - see the note above. Everything typed into a blocked
# window is refused, and the only thing that lifts it is the widget. The decoded
# prompt is still read whole, because it is about to be saved rather than sent.

# From here the prompt is refused, so cut it first.
mkdir -p "$CD" 2>/dev/null
if [ -n "$prompt" ]; then
  printf '%s' "$prompt" > "$CD/$sid.prompt" 2>/dev/null
  # clip.exe reads the console codepage unless it is handed UTF-16LE with a BOM,
  # so anything non-ASCII arrives as mojibake without this conversion. iconv
  # ships with Git Bash; if it is missing, plain bytes are still better than no
  # clipboard at all, and the file above is the copy that always survives.
  if command -v iconv >/dev/null 2>&1; then
    { printf '\xff\xfe'; printf '%s' "$prompt" | iconv -f UTF-8 -t UTF-16LE 2>/dev/null; } |
      clip.exe 2>/dev/null
  else
    printf '%s' "$prompt" | clip.exe 2>/dev/null
  fi
fi

msg="[token-block] $why, so this window is refusing every prompt - it has been
checkpointed already, and the cheapest thing it can do now is end.
Your prompt has been cut to the clipboard (and saved to $CD/$sid.prompt).
/clear this window and paste it into the fresh one, or unpark the checkpoint there.
Nothing typed here lifts the block: press u on this row in the token widget, or run
token-sessions.sh --unblock ${sid%%-*} from any shell."

# Both refusal forms, because they are honoured by different paths and a block
# that silently fails open is worse than one that says itself twice: the JSON on
# stdout for a host that reads it, exit 2 with the same text on stderr for one
# that reads that. Whichever is honoured, the prompt does not go through and the
# user is told why.
printf '{"continue":false,"stopReason":%s,"decision":"block","reason":%s}\n' \
  "$(printf '%s' "$msg" | awk 'BEGIN{printf "\""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\\n", $0} END{printf "\""}')" \
  "$(printf '%s' "$msg" | awk 'BEGIN{printf "\""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\\n", $0} END{printf "\""}')"
printf '%s\n' "$msg" >&2
exit 2
