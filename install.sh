#!/usr/bin/env bash
# Install the token tools into ~/.claude.
#
# The scripts address each other by absolute path ($HOME/.claude/...), so they
# have to live there rather than being run out of the repo. This copies them,
# backs up anything it would overwrite, and prints the settings.json wiring.
#
# The widget is the interface, so this also puts a "Claude Widget" shortcut on
# the Desktop - the only way in, now that the terminal pane is retired.
#
#   ./install.sh            copy everything + slash commands, then print the wiring
#   ./install.sh --link     symlink instead of copy (edit in the repo, live)
#   ./install.sh --no-cmds  skip the /park, /tokens, /unpark slash commands
#   ./install.sh --dry-run  say what would happen, change nothing
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
MODE=copy; CMDS=1; DRY=0
for a in "$@"; do
  case "$a" in
    --link)    MODE=link ;;
    --no-cmds) CMDS=0 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[ -d "$DEST" ] || { echo "no $DEST - install Claude Code and run it once first" >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)

place() {  # place <src file> <dest file>
  s="$1"; d="$2"
  if [ -e "$d" ] && ! [ -L "$d" ]; then
    if cmp -s "$s" "$d"; then echo "  same    $(basename "$d")"; return; fi
    [ "$DRY" = 1 ] || cp -p "$d" "$d.bak-$STAMP"
    echo "  backup  $(basename "$d") -> $(basename "$d").bak-$STAMP"
  fi
  if [ "$DRY" = 1 ]; then echo "  would   $MODE $(basename "$d")"; return; fi
  rm -f "$d"
  if [ "$MODE" = link ]; then ln -s "$s" "$d"; else cp "$s" "$d"; fi
  chmod +x "$d" 2>/dev/null
  echo "  $MODE    $(basename "$d")"
}

echo "scripts -> $DEST"
for f in "$SRC"/bin/*.sh; do place "$f" "$DEST/$(basename "$f")"; done

echo "windows -> $DEST"
for f in "$SRC"/windows/*; do place "$f" "$DEST/$(basename "$f")"; done

echo "share   -> $DEST"
for f in "$SRC"/share/*; do place "$f" "$DEST/$(basename "$f")"; done

if [ "$CMDS" = 1 ]; then
  echo "commands -> $DEST/commands"
  [ "$DRY" = 1 ] || mkdir -p "$DEST/commands"
  for f in "$SRC"/commands/*.md; do place "$f" "$DEST/commands/$(basename "$f")"; done
fi

# Where this clone lives, so the pane can offer an update and take it: u runs a
# pull here and then this installer again. Recorded on every install so moving
# the clone fixes itself the next time you run it.
if [ "$DRY" = 0 ]; then
  printf '%s
' "$SRC" > "$DEST/token-tools-src"
  echo "source  -> $DEST/token-tools-src"
fi

# The desktop shortcut. The widget IS the interface - there is no terminal pane
# to fall back on any more - so an install that stops before this one leaves
# nothing to open, which is how a fresh clone used to end up looking like a
# different program. A .lnk is a COM object rather than a file, so this is the
# one step that has to go through PowerShell.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "shortcut -> Desktop"
    winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
    if powershell -NoProfile -ExecutionPolicy Bypass          -File "$(winpath "$SRC/windows/token-shortcut.ps1")"          -Dest "$(winpath "$DEST")" $([ "$DRY" = 1 ] && printf %s -DryRun); then :; else
      echo "  failed - make it by hand: a shortcut to" >&2
      echo "  wscript.exe \"%USERPROFILE%\.claude\token-widget.vbs\"" >&2
    fi ;;
  *) echo "shortcut -> skipped (not Windows; the widget is a Windows program)" ;;
esac

cat <<'WIRING'

--------------------------------------------------------------------
One manual step left: the hooks and the status line.

Merge this into ~/.claude/settings.json (keep any keys you already have):

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

Then restart Claude Code. The Stop hook starts writing token-history.csv on
the next cycle; everything else here reads that file, so the views are thin
until you have ~20 cycles on disk.

  the "Claude Widget" shortcut on your Desktop   the live readout
  bash ~/.claude/token-cycles.sh                 this session, per cycle
  bash ~/.claude/token-cycles.sh --stats         across sessions
--------------------------------------------------------------------
WIRING
