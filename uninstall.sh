#!/usr/bin/env bash
# Remove what install.sh placed. Your data (token-history.csv, checkpoints,
# titles) is never touched - delete those by hand if you want them gone.
#
#   ./uninstall.sh            remove the scripts, the shortcut and the commands
#   ./uninstall.sh --dry-run  say what would go, change nothing
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# Derived from the clone rather than listed here, so a file added to the repo is
# a file this removes. Only program files live in those three directories; the
# data sits beside them in ~/.claude and is not named here at all.
for d in bin windows share; do
  for f in "$SRC/$d"/*; do
    [ -e "$f" ] || continue
    t="$DEST/$(basename "$f")"
    [ -e "$t" ] || [ -L "$t" ] || continue
    if [ "$DRY" = 1 ]; then echo "  would  remove $(basename "$t")"
    else rm -f "$t" && echo "  removed $(basename "$t")"; fi
  done
done
for f in token-tools-src token-sessions.minttyrc token-sessions-launch.sh; do
  # The last two are the retired terminal pane; removed here so an install that
  # predates the widget-only layout does not leave them behind.
  [ -e "$DEST/$f" ] || continue
  if [ "$DRY" = 1 ]; then echo "  would  remove $f"; else rm -f "$DEST/$f" && echo "  removed $f"; fi
done
for f in park.md tokens.md unpark.md; do
  [ -e "$DEST/commands/$f" ] || continue
  if [ "$DRY" = 1 ]; then echo "  would  remove commands/$f"
  else rm -f "$DEST/commands/$f" && echo "  removed commands/$f"; fi
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    powershell -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SRC/windows/token-shortcut.ps1" 2>/dev/null || printf '%s' "$SRC/windows/token-shortcut.ps1")" \
      -Remove $([ "$DRY" = 1 ] && printf %s -DryRun) ;;
esac

echo
echo "Still to do by hand: drop the statusLine and the two hooks from"
echo "$DEST/settings.json, then restart Claude Code."
echo "Data kept: token-history.csv, token-titles.tsv, token-nicks.tsv,"
echo "            token-version.state, checkpoints/"
