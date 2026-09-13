#!/usr/bin/env bash
# token-dashboard.sh - the retrospective half of token-sessions, as one HTML
# file you can open in the browser that is already on this machine.
#
# Deliberately zero-dependency: no server, no node, no CDN, no package. The
# page is written whole, with its data inlined as a JSON literal, and opened
# over file://. That is also why there is no framework - fetch() is blocked
# from a file:// origin, so new data can only arrive by rewriting the page,
# and a reconciler has nothing to reconcile against after a reload.
#
# The live view is the widget's job (token-widget.ps1). This is the sit-down
# one: where the week went, what a cycle costs, and whether it is improving.
#
#   token-dashboard.sh              write the page
#   token-dashboard.sh --open       write it and open it
#   token-dashboard.sh --watch [n]  rewrite every n seconds (default 60)
#   token-dashboard.sh --out FILE   somewhere other than ~/.claude

set -u
CL="$HOME/.claude"
SRC="$CL/token-sessions.sh"
OUT="$CL/token-dashboard.html"
OPEN=0; WATCH=0; EVERY=60; want_out=0

for a in "$@"; do
  if [ "$want_out" = 1 ]; then want_out=0; OUT="$a"; continue; fi
  case "$a" in
    --open|-o)  OPEN=1 ;;
    --watch|-w) WATCH=1 ;;
    --out)      want_out=1 ;;
    --out=*)    OUT="${a#*=}" ;;
    [0-9]*)     EVERY="$a" ;;
    --help|-h)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'token-dashboard: unknown option %s\n' "$a" >&2; exit 2 ;;
  esac
done
[ -x "$SRC" ] || { printf 'token-dashboard: %s not found\n' "$SRC" >&2; exit 1; }

TPL="$CL/token-dashboard.template.html"
[ -r "$TPL" ] || { printf 'token-dashboard: %s not found\n' "$TPL" >&2; exit 1; }

write_page() {
  local json tmp
  tmp="$OUT.$$"
  json=$("$SRC" --json-full --no-update-check 2>/dev/null)
  [ -n "$json" ] || { printf 'token-dashboard: no JSON from token-sessions.sh\n' >&2; return 1; }
  # awk rather than sed: the payload is full of backslashes and ampersands,
  # both of which sed's replacement side would eat.
  printf '%s' "$json" > "$tmp.json"
  awk -v jf="$tmp.json" -v refresh="$WATCH" -v every="$EVERY" '
    /__REFRESH__/ {
      if (refresh == 1) printf "<meta http-equiv=\"refresh\" content=\"%d\">\n", every
      next }
    /__DATA__/ {
      while ((getline l < jf) > 0) print l
      close(jf); next }
    { print }' "$TPL" > "$tmp" && mv -f "$tmp" "$OUT"
  rm -f "$tmp.json"
}

if [ "$WATCH" = 1 ]; then
  write_page || exit 1
  [ "$OPEN" = 1 ] && start "" "$(cygpath -w "$OUT" 2>/dev/null || printf '%s' "$OUT")" 2>/dev/null
  printf 'token-dashboard: rewriting %s every %ss (ctrl-c to stop)\n' "$OUT" "$EVERY"
  while sleep "$EVERY"; do write_page || break; done
else
  write_page || exit 1
  printf '%s\n' "$OUT"
  [ "$OPEN" = 1 ] && start "" "$(cygpath -w "$OUT" 2>/dev/null || printf '%s' "$OUT")" 2>/dev/null
fi
exit 0
