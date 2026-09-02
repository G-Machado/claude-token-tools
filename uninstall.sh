#!/usr/bin/env bash
# Remove what install.sh placed. Your data (token-history.csv, checkpoints,
# titles) is never touched - delete those by hand if you want them gone.
set -u
DEST="$HOME/.claude"
FILES="token-sessions.sh token-cycles.sh token-gap-warn.sh token-park-context.sh
token-unpark-context.sh token-sessions-launch.sh token-failsafe-probe.sh
token-sessions.minttyrc token-tools-src"
for f in $FILES; do [ -e "$DEST/$f" ] && rm -f "$DEST/$f" && echo "removed $f"; done
for f in park.md tokens.md unpark.md; do
  [ -e "$DEST/commands/$f" ] && rm -f "$DEST/commands/$f" && echo "removed commands/$f"
done
echo
echo "Still to do by hand: drop the statusLine and the two hooks from"
echo "$DEST/settings.json, then restart Claude Code."
echo "Data kept: token-history.csv, token-titles.tsv, token-nicks.tsv,"
echo "            token-version.state, checkpoints/"
