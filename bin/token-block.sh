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

# The one thing done for every prompt (2026-09-15): stamp when a PERSON last
# prompted this session, for the safe-park in token-sessions.sh --poke-due. It
# needs "has anyone typed since the checkpoint", and the CLI's own last-turn
# time cannot say - a renewal's "reply ok" and a /park are turns too. So the
# poke's own two lines are not stamped, and neither is a prompt this hook is
# about to refuse. Builtins only - read, =~, a redirection - so the fast path
# still spawns nothing; mkdir runs once per machine.
HD="${TOKEN_HUMAN_DIR:-$HOME/.claude/token-human}"
IFS= read -r -d '' payload || true
re_sid='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
re_auto='"prompt"[[:space:]]*:[[:space:]]*"(\[auto-renew:|/park["[:space:]])'
if [[ $payload =~ $re_sid ]]; then
  hsid=${BASH_REMATCH[1]}
  if [ ! -f "$BD/$hsid" ] && ! [[ $payload =~ $re_auto ]]; then
    { [ -d "$HD" ] || mkdir -p "$HD"; } 2>/dev/null && : > "$HD/$hsid" 2>/dev/null
  fi
fi

# There used to be a one-stat fast path here ([ -d "$BD" ] || exit 0). The cold
# block below has to look at every prompt, so it went (2026-09-23): the cost is
# one sed and one awk over token-history.csv per prompt, tens of milliseconds.

[ -n "$payload" ] || exit 0

# session_id and prompt out of the payload without a JSON parser. The prompt is
# the only field here that can contain arbitrary text - quotes, newlines encoded
# as \n, braces - so it is taken last and taken whole, and never used to build
# another command line.
sid=$(printf '%s' "$payload" |
      sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$sid" ] || exit 0

# --- cold block (2026-09-23) --------------------------------------------------
# A prompt into a window whose cache has lapsed rewrites the whole window at 2x
# the moment it is sent - token-gap-warn.sh can only report that afterwards.
# Above ~72k, /clear + resume is cheaper than that rewrite ((65k floor + ~7k
# catch-up) x 2 vs context x 2), so refuse the prompt BEFORE it is sent, through
# the same block the auto-park uses: prompt to clipboard, widget `u` lifts it.
# Lifting it is a decision, remembered per cycle: token-cold/<sid> holds the
# history row it fired on, so an unblocked window is not re-blocked until a new
# cycle has run. TOKEN_COLD_BLOCK=0 turns this off.
COLDK="${TOKEN_COLD_BLOCK:-72000}"
COLDD="${TOKEN_COLD_DIR:-$HOME/.claude/token-cold}"
if [ "$COLDK" -gt 0 ] 2>/dev/null && [ ! -f "$BD/$sid" ] && [ -f "$HOME/.claude/token-history.csv" ]; then
  cold=$(awk -F, -v key="${sid:0:8}" -v ttl="${TOKEN_GAP_TTL_MINUTES:-60}" -v minctx="$COLDK" \
             -v nowts="$(date '+%Y %m %d %H %M %S')" '
    $2 == key { ts = $1; ctx = $6 + 0 }
    END { if (ts == "") exit
          s = ts; gsub(/[-:]/, " ", s); gap = (mktime(nowts) - mktime(s " 00")) / 60
          if (gap >= ttl && ctx >= minctx) printf "%s|%.1f|%d\n", ts, gap / 60, ctx }' \
         "$HOME/.claude/token-history.csv" 2>/dev/null)
  if [ -n "$cold" ]; then
    IFS='|' read -r cts chrs cctx <<< "$cold"
    if [ "$(cat "$COLDD/$sid" 2>/dev/null)" != "$cts" ]; then
      mkdir -p "$BD" "$COLDD" 2>/dev/null
      printf '%s' "$cts" > "$COLDD/$sid" 2>/dev/null
      printf 'the cache expired (%sh idle) on a %dk window - sending would rewrite it at 2x, ~%dk weighted, where /clear + resume costs ~143k\n' \
        "$chrs" $(( cctx / 1000 )) $(( cctx * 2 / 1000 )) > "$BD/$sid" 2>/dev/null
    fi
  fi
fi

# --- hard stop at 300k (2026-09-23) --------------------------------------------
# Past ctxmax every cycle re-reads ~6 full windows of 300k+, and a cut already
# paid for itself around 150k. Same block and the same per-cycle memory as the
# cold block (token-cold/<sid>.max holds the row it fired on): widget `u` lifts
# it for one cycle, and the next cycle past 300k is refused again. /park,
# /compact, /clear and /exit pass - they are the way out. TOKEN_MAX_BLOCK=0 = off.
MAXK="${TOKEN_MAX_BLOCK:-300000}"
if [ "$MAXK" -gt 0 ] 2>/dev/null && [ ! -f "$BD/$sid" ] && [ -f "$HOME/.claude/token-history.csv" ]; then
  big=$(awk -F, -v key="${sid:0:8}" -v m="$MAXK" '$2 == key { ts = $1; ctx = $6 + 0 }
    END { if (ts != "" && ctx >= m) printf "%s|%d\n", ts, ctx }' "$HOME/.claude/token-history.csv" 2>/dev/null)
  if [ -n "$big" ]; then
    IFS='|' read -r bts bctx <<< "$big"
    if [ "$(cat "$COLDD/$sid.max" 2>/dev/null)" != "$bts" ]; then
      mkdir -p "$BD" "$COLDD" 2>/dev/null
      printf '%s' "$bts" > "$COLDD/$sid.max" 2>/dev/null
      printf 'the window is past %dk (%dk) - every cycle here re-reads it ~6 times\n' $(( MAXK / 1000 )) $(( bctx / 1000 )) > "$BD/$sid" 2>/dev/null
    fi
  fi
fi

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
# A cold block exists to stop the 2x rewrite, and /clear and /exit send nothing
# to the API - they are the advice itself, so they pass. (The marks block stays
# total; see above.)
case "$why" in "the cache expired"*)
  case "$prompt" in /clear|/clear\ *|/exit|/exit\ *|/quit) exit 0 ;; esac ;;
"the window is past"*)
  case "$prompt" in /clear|/clear\ *|/exit|/exit\ *|/quit|/park|/park\ *|/compact|/compact\ *) exit 0 ;; esac ;;
# /handoff blocks the window it leaves: the work is in the new one now, and a
# prompt here would fork the strand. Leaving is the one thing it should do.
"handed off"*)
  case "$prompt" in /exit|/exit\ *|/quit) exit 0 ;; esac ;;
esac

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

case "$why" in
  "the cache expired"*) state="a lapsed window only gets dearer to keep; if the work matters,
lift the block and send once - the rewrite is paid once, then it is warm again." ;;
  "the window is past"*) state="/park then /clear (new topic) or /compact (same topic) - both pass this block.
If this cycle really must run here, lift it once; the next cycle past the bar is refused again." ;;
  "handed off"*) state="it is read-only now; the work carries on in the window
/handoff opened. Close this one, or lift the block to ask it something." ;;
  *) state="it has been checkpointed already, and the cheapest thing it can do now is end." ;;
esac
case "$why" in
  "handed off"*) where="Paste it into the new window instead - /exit here passes." ;;
  *) where="/clear this window and paste it into the fresh one, or unpark the checkpoint there." ;;
esac
msg="[token-block] $why, so this window is refusing every prompt - $state
Your prompt has been cut to the clipboard (and saved to $CD/$sid.prompt).
$where
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
