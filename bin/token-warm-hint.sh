#!/usr/bin/env bash
# SessionStart hook: say so when this directory already has a warm window.
#
# Measured 2026-09-11 over the preceding week: 25 of 45 sessions opened here ran
# two cycles or fewer - 56% of every session started - and each paid the ~61k
# cold floor to answer a prompt or two. The window that could have answered it
# for 0.1x was usually still open in another terminal. Nothing on screen ever
# said so, which is the whole reason the habit survives.
#
# Deliberately NOT a call to token-sessions.sh --json: that takes ~4s and this
# runs before the first prompt. It reads one project directory instead - the
# transcripts for THIS cwd - and nothing else.
#
# Silence is the correct output when nothing is warm. A hint that fires on every
# session start is one nobody reads by the third day.
set -u
CL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TTL="${TOKEN_CACHE_TTL_MIN:-60}"
FLOOR_K="${TOKEN_WARM_MIN_CTX:-60}"      # under this, rebuilding beats resuming
MARGIN="${TOKEN_WARM_MARGIN_MIN:-5}"     # minutes of cache life worth walking to

# The hook payload carries the session that is STARTING and the directory it
# started in. Without the id this would cheerfully recommend the session it is
# running inside; without the cwd it would guess at $PWD, which is not the same
# thing when the CLI was launched from elsewhere.
payload=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[ :]*"\([^"]*\)".*/\1/p')
cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[ :]*"\([^"]*\)".*/\1/p')
[ -n "$cwd" ] || cwd="$PWD"

# The CLI encodes a project directory into a folder name by replacing the drive
# colon and every separator with "-", and the case of the drive letter is not
# stable between launches (both "C--Users-you" and "c--Users-you" exist on
# this machine), so the compare below is case-insensitive. The first expression
# folds the doubled backslashes JSON delivers back to one separator; without it
# every one of them would widen into two dashes and nothing would ever match.
enc=$(printf '%s' "$cwd" | sed -e 's|[\][\]|/|g' -e 's|[:/]|-|g' -e 's|[\]|-|g')
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
dir=""
for d in "$CL"/projects/*/; do
  [ -d "$d" ] || continue
  [ "$(lc "$(basename "$d")")" = "$(lc "$enc")" ] && { dir="$d"; break; }
done
[ -n "$dir" ] || exit 0

now=$(date +%s)
best_ctx=0; best_left=0; best_sid=""; best_name=""
for f in "$dir"*.jsonl; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in "$sid"*) continue ;; esac
  # mtime is a cheap pre-filter only. It is NOT the last activity - resuming a
  # session touches the file without adding a record - so anything that passes
  # here still has to prove itself from the last record's own timestamp.
  m=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ $(( (now - m) / 60 )) -lt "$TTL" ] || continue
  set -- $(tail -c 300000 "$f" 2>/dev/null | awk '
    function jn(pat,   r) {
      if (match($0, pat)) { r = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", r); return r + 0 }
      return 0 }
    /"cache_read_input_tokens":/ {
      if (match($0, /"timestamp":"[0-9-]+T[0-9:]+/)) {
        d = substr($0, RSTART + 13, 19); gsub(/[-T:]/, " ", d)
        e = mktime(d)
        if (e > lt) {
          lt = e
          c = jn("\"input_tokens\":[0-9]+") + jn("\"cache_creation_input_tokens\":[0-9]+")
          c = c + jn("\"cache_read_input_tokens\":[0-9]+") } } }
    # The age is computed HERE, not against date +%s outside, because the record
    # timestamps are UTC and mktime reads them as local: subtracting a real epoch
    # from them buys the zone offset as free cache life. Measured on this machine
    # at UTC-3 the first version reported 239 minutes left on a 60-minute TTL.
    # Both sides through mktime under the same rule, and the offset cancels.
    END { nowu = mktime(strftime("%Y %m %d %H %M %S", systime(), 1))
          print (lt > 0 ? int((nowu - lt) / 60) : -1), c+0 }')
  age=${1:--1}; ctx=${2:-0}
  [ "$age" -ge 0 ] || continue
  left=$(( TTL - age ))
  [ "$left" -gt "$MARGIN" ] || continue
  [ "$ctx" -ge $(( FLOOR_K * 1000 )) ] || continue
  if [ "$ctx" -gt "$best_ctx" ]; then
    best_ctx=$ctx; best_left=$left; best_sid=$(basename "${f%.jsonl}")
    best_name=$(sed -n 's/.*"type":"user".*"content":"\([^"]\{0,60\}\).*/\1/p' "$f" 2>/dev/null | head -1)
  fi
done

[ "$best_ctx" -gt 0 ] || exit 0
printf 'This directory already has a warm %dk window open: %s, %dm of cache left - "%s".\n' \
  $(( best_ctx / 1000 )) "${best_sid:0:8}" "$best_left" "${best_name:-untitled}"
printf 'Reading it back costs 0.1x; this session pays the ~61k cold floor instead. Offer "claude -r %s" before doing small work here.\n' \
  "${best_sid:0:8}"
exit 0
