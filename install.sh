#!/usr/bin/env bash
# Install the token tools into ~/.claude.
#
# The scripts address each other by absolute path ($HOME/.claude/...), so they
# have to live there rather than being run out of the repo. This copies them,
# backs up anything it would overwrite, and prints the settings.json wiring.
#
#   ./install.sh            copy scripts + slash commands, then print the wiring
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

echo "config  -> $DEST"
place "$SRC/config/token-sessions.minttyrc" "$DEST/token-sessions.minttyrc"

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

  bash ~/.claude/token-sessions.sh --watch    the live pane
  bash ~/.claude/token-cycles.sh              this session, per cycle
  bash ~/.claude/token-cycles.sh --stats      across sessions
--------------------------------------------------------------------
WIRING
