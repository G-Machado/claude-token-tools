#!/usr/bin/env bash
# token-window-keeper.sh - keep every idle account's five-hour window ticking,
# phased so their reset boundaries are spread evenly instead of clustered.
#
# Why this exists
# ---------------
# A plan's five-hour window starts at the first request and resets exactly five
# hours later. An account whose window is ALREADY RUNNING and unused is worth
# strictly more than one sitting stopped: switching to it hands you the same
# full bucket either way, but the running one refreshes sooner. So the cheapest
# throughput there is, is making sure no idle account has its clock stopped.
#
# Phase matters as much as running-or-not, and it is a ONE-TIME choice. A reset
# repeats every five hours at the same phase - start + 5h == start, mod 5h - so
# an account's reset phase is fixed the moment its window first starts, and only
# moves if the window is ever allowed to lapse. Two accounts started ten minutes
# apart give you two boundaries ten minutes apart and then a 4h50m drought.
# Started 2h30m apart they give you a boundary every 2h30m, forever. This script
# spends that one choice deliberately: an idle account is started at the
# midpoint of the largest gap in the set of reset phases already in play.
#
# The wait for that midpoint is bounded (MAXWAIT). Ticking beats perfectly
# placed: if the ideal moment is further off than the bound, the best moment
# reachable inside the bound is used instead.
#
# Cost. One ping, measured 2026-09-02 against account 2:
#   in 10   out 103   cache-write 19,389   cache-read 16,265   $0.0409 list
# About 0.2% of a seven-day window, roughly five pings per account per day.
#
# Rails, because this fires real requests unattended:
#   - never the active account; never one whose window is already running
#   - never inside MIN_GAP of that account own last ping (loop backstop)
#   - never an account already past MAX_7D percent of its weekly window
#   - ~/.claude/token-keeper.off or TOKEN_KEEPER_DISABLE=1 stops it dead
#   - --dry-run decides, logs, and sends nothing
#
# Usage:
#   token-window-keeper.sh                 one scheduler pass
#   token-window-keeper.sh --dry-run       decide and log, send nothing
#   token-window-keeper.sh --status        print the picture, decide nothing
#   token-window-keeper.sh --now <n|all>   ignore phase, start that window now
set -u

CL="$HOME/.claude"
STATE="$CL/token-keeper.state"
LOG="$CL/token-keeper.log"
OFF="$CL/token-keeper.off"
LOCK="$CL/token-keeper.lock"

W=18000                                   # the five-hour window, in seconds
INTERVAL="${TOKEN_KEEPER_INTERVAL:-900}"  # how often the scheduler runs us
MIN_GAP="${TOKEN_KEEPER_MIN_GAP:-16200}"  # 4h30m: a ping this recent means the
                                          # window is already ours; never repeat
MAX_7D="${TOKEN_KEEPER_MAX_7D:-90}"       # leave a nearly-spent weekly alone
MODEL="${TOKEN_KEEPER_MODEL:-claude-haiku-4-5-20251001}"
PROMPT="${TOKEN_KEEPER_PROMPT:-hi}"
STEP=300                                  # phase search granularity, 5 minutes

MODE=run; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --status)  MODE=status ;;
    --now)     MODE=now; ONLY="${2:-all}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

now_s() { date +%s; }
stamp()  { date +"%Y-%m-%d %H:%M"; }
log() {
  local line; line=$(printf '%s\t' "$@"); line=${line%	}
  printf '%s\t%s\n' "$(stamp)" "$line" >> "$LOG"
}

# 96 runs a day would append to the decision log forever. token-keeper.out is not
# trimmed here - the .vbs truncates it per run, and it is open for writing while
# this runs, so a rename would only fail with a sharing violation on Windows.
trim() {
  local f="$1" keep="$2"
  [ -f "$f" ] || return 0
  [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt "$(( keep * 2 ))" ] || return 0
  tail -n "$keep" "$f" > "$f.trim" 2>/dev/null && mv -f "$f.trim" "$f" 2>/dev/null
}
trim "$LOG" 2000

CSWAP=""
for _c in "$HOME/.local/bin/cswap.exe" "$HOME/.local/bin/cswap"; do
  [ -x "$_c" ] && { CSWAP="$_c"; break; }
done
[ -n "$CSWAP" ] || CSWAP=$(command -v cswap 2>/dev/null || true)
if [ -z "$CSWAP" ]; then
  log ERROR - "no cswap on PATH - nothing to keep"
  echo "no cswap found" >&2; exit 1
fi

# One pass at a time. A scheduler that overlapped itself would double-ping.
if [ "$MODE" != status ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    # A lock older than ten minutes is a crashed run, not a live one.
    if [ -d "$LOCK" ] && [ $(( $(now_s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) )) -gt 600 ]; then
      rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
fi

if [ "$MODE" = run ] || [ "$MODE" = now ]; then
  if [ -f "$OFF" ] || [ "${TOKEN_KEEPER_DISABLE:-0}" = 1 ]; then
    log off - "token-keeper.off present or TOKEN_KEEPER_DISABLE=1"
    echo "keeper is off (~/.claude/token-keeper.off)"; exit 0
  fi
fi

# ---------------------------------------------------------------- account read
# cswap polls the ACTIVE account every couple of minutes and the others on a
# slower timer, so its view of an idle account can be ten minutes stale. That is
# why the state file exists: a ping we made ourselves is authoritative for when
# that window started, and outranks a stale "not running" from cswap.
RAW="$CL/.cswap-usage.json"
if [ ! -s "$RAW" ] || [ $(( $(now_s) - $(stat -c %Y "$RAW" 2>/dev/null || echo 0) )) -ge 60 ]; then
  "$CSWAP" list --json > "$RAW.$$" 2>/dev/null && mv -f "$RAW.$$" "$RAW" 2>/dev/null
  rm -f "$RAW.$$" 2>/dev/null
fi
[ -s "$RAW" ] || { log ERROR - "cswap list --json produced nothing"; exit 1; }

ACCTS=$(awk '
  function str(l,   r) { if (match(l, /: *"[^"]*"/)) { r = substr(l, RSTART, RLENGTH)
      sub(/^:[ ]*"/, "", r); sub(/"$/, "", r); return r } return "" }
  function num(l,   r) { if (match(l, /: *-?[0-9.]+/)) { r = substr(l, RSTART, RLENGTH)
      sub(/^:[ ]*/, "", r); return r + 0 } return -1 }
  /"activeAccountNumber"/ { next }
  /"number":/ { n++; N[n] = num($0); blk = ""; R5[n] = ""; P5[n] = -1; P7[n] = -1
                A[n] = 0; AG[n] = -1; U[n] = "ok"; next }
  n == 0 { next }
  /"email":/           { E[n] = str($0); next }
  /"active":/          { A[n] = ($0 ~ /true/) ? 1 : 0; next }
  /"usageStatus":/     { U[n] = str($0); next }
  /"fiveHour"/         { blk = "5"; next }
  /"sevenDay"/         { blk = "7"; next }
  /"pct":/             { if (blk == "5") P5[n] = num($0); else if (blk == "7") P7[n] = num($0); next }
  /"resetsAt":/        { if (blk == "5") R5[n] = str($0); next }
  /"usageAgeSeconds":/ { AG[n] = num($0); blk = ""; next }
  # A stopped window has no resetsAt, and an EMPTY field here would be eaten:
  # tab counts as IFS whitespace, so read collapses a run of them and every
  # column after the hole shifts left. "-" keeps the shape.
  END { for (i = 1; i <= n; i++)
          printf "%d\t%s\t%d\t%s\t%.1f\t%s\t%.1f\t%d\n",
            N[i], (E[i] == "" ? "-" : E[i]), A[i], (U[i] == "" ? "ok" : U[i]),
            P5[i], (R5[i] == "" ? "-" : R5[i]), P7[i], AG[i] }' "$RAW")

if [ -z "$ACCTS" ]; then
  log ERROR - "parsed 0 accounts out of cswap - the keeper is a silent no-op"
  echo "parsed 0 accounts from cswap" >&2; exit 1
fi
NACCT=$(printf '%s\n' "$ACCTS" | wc -l | tr -d ' ')

# Ideal spacing is W/N, so a search bounded at W/N can always reach the midpoint
# of the largest gap. The wait is worth its length: phase is durable, so one
# deferred start buys a boundary in the right place for as long as the keeper
# keeps that window alive. A stopped account still hands you a full bucket the
# moment you switch to it - all the wait forgoes is an earlier refresh.
MAXWAIT="${TOKEN_KEEPER_MAXWAIT:-$(( W / NACCT ))}"
[ "$MAXWAIT" -lt 1800 ] && MAXWAIT=1800

iso_epoch() {                             # 2026-09-02T22:50:00.033891+00:00 -> epoch
  local t; t=$(printf '%s' "$1" | sed 's/\.[0-9]*//')
  [ -n "$t" ] || { echo -1; return; }
  date -u -d "$t" +%s 2>/dev/null || echo -1
}

state_ping() {
  [ -f "$STATE" ] || { echo 0; return; }
  awk -F'\t' -v n="$1" '$1 == n { v = $2 } END { print (v == "" ? 0 : v) }' "$STATE"
}
state_set() {                             # account, last-ping epoch
  local tmp="$STATE.$$"
  { [ -f "$STATE" ] && awk -F'\t' -v n="$1" '$1 != n' "$STATE"
    printf '%s\t%s\n' "$1" "$2"; } > "$tmp"
  mv -f "$tmp" "$STATE"
}

# ------------------------------------------------------------- window snapshot
# start < 0 means the clock is stopped. Phases are starts mod W, and a reset has
# the same phase as its start, so one set answers both questions.
NOW=$(now_s)
PHASES=""; ROWS=""
while IFS=$'\t' read -r n email active status p5 r5 p7 age; do
  [ -n "${n:-}" ] || continue
  start=-1
  if [ -n "${r5:-}" ] && [ "$r5" != - ]; then
    re=$(iso_epoch "$r5")
    if [ "$re" -gt 0 ] 2>/dev/null; then start=$(( re - W )); fi
  fi
  lp=$(state_ping "$n")
  if [ "$start" -lt 0 ] && [ "$lp" -gt 0 ] && [ $(( NOW - lp )) -lt "$W" ]; then
    start=$lp                             # our own ping beats a stale cswap read
  fi
  [ "$start" -ge 0 ] && PHASES="$PHASES $(( start % W ))"
  ROWS="$ROWS$n	$email	$active	$status	$p5	$p7	$start	$lp	$age
"
done <<EOF
$ACCTS
EOF

hhmm() { printf '%dh%02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

# Best moment in [now, now+MAXWAIT]: the one whose phase sits furthest from
# every reset phase already in play. With none in play, now is as good as any.
#
# Phase can only ever move FORWARD - a window cannot be started before it has
# lapsed, and the scheduler tick lands somewhere after that, so every renewal is
# a little late. That drift is why the search runs at every lapse rather than
# once: absolute phases creep, but the thing being maximised is the distance
# BETWEEN them, so a renewal that would crowd another account is held back
# instead. Relative spacing is what matters and it self-corrects; do not add a
# "preserve the stored phase exactly" shortcut, it would defeat that.
best_time() {
  local phases="$1"
  case "$phases" in *[0-9]*) ;; *) echo "$NOW"; return ;; esac
  awk -v now="$NOW" -v w="$W" -v maxw="$MAXWAIT" -v step="$STEP" -v ph="$phases" '
    BEGIN {
      k = split(ph, P, " ")
      bt = now; bs = -1
      for (t = now; t <= now + maxw; t += step) {
        p = t % w; m = w
        for (i = 1; i <= k; i++) {
          d = (p - P[i]) % w; if (d < 0) d += w; if (w - d < d) d = w - d
          if (d < m) m = d }
        if (m > bs) { bs = m; bt = t } }
      print bt }'
}

# ------------------------------------------------------------------- the ping
ping_account() {
  local n="$1" why="$2" out rc cw cr ot cost
  if [ "$MODE" = dry ]; then
    log would-ping "$n" "$why"
    printf '    would ping now (%s)\n' "$why"
    PHASES="$PHASES $(( NOW % W ))"
    return 0
  fi
  out=$(cd "${TMPDIR:-/tmp}" && timeout 180 "$CSWAP" run "$n" -- \
          -p "$PROMPT" --model "$MODEL" --output-format json 2>&1 | tail -c 4000)
  rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q '"is_error":false'; then
    log FAILED "$n" "$why" "rc=$rc" "$(printf '%s' "$out" | tr '\t\n' '  ' | tail -c 200)"
    printf '    ping FAILED (rc=%s)\n' "$rc" >&2
    return 1
  fi
  cw=$(printf '%s' "$out" | grep -o '"cacheCreationInputTokens":[0-9]*' | head -1 | tr -dc 0-9)
  cr=$(printf '%s' "$out" | grep -o '"cacheReadInputTokens":[0-9]*'     | head -1 | tr -dc 0-9)
  ot=$(printf '%s' "$out" | grep -o '"outputTokens":[0-9]*'             | head -1 | tr -dc 0-9)
  cost=$(printf '%s' "$out" | grep -o '"costUSD":[0-9.]*' | head -1 | cut -d: -f2)
  state_set "$n" "$NOW"
  log ping "$n" "$why" "write=${cw:-?}" "read=${cr:-?}" "out=${ot:-?}" "usd=${cost:-?}"
  printf '    started - resets %s  (write %s, $%s)\n' \
    "$(date -d "@$(( NOW + W ))" +%H:%M 2>/dev/null)" "${cw:-?}" "${cost:-?}"
  PHASES="$PHASES $(( NOW % W ))"
  return 0
}

# --------------------------------------------------------------------- passes
printf 'token-window-keeper  %s   %d accounts   window %s   max wait %s\n' \
  "$(stamp)" "$NACCT" "$(hhmm $W)" "$(hhmm $MAXWAIT)"

STARTED=0; STOPPED=0
while IFS=$'\t' read -r n email active status p5 p7 start lp age; do
  [ -n "${n:-}" ] || continue
  if [ "$start" -ge 0 ]; then
    printf '  %s %-30s 5h %5s%%  ticking, resets in %-7s at %s\n' \
      "$n" "$email" "$p5" "$(hhmm $(( start + W - NOW )))" \
      "$(date -d "@$(( start + W ))" +%H:%M 2>/dev/null)"
  else
    STOPPED=$(( STOPPED + 1 ))
    printf '  %s %-30s 5h %5s%%  STOPPED\n' "$n" "$email" "$p5"
  fi

  [ "$MODE" = status ] && continue

  if [ "$MODE" = now ]; then
    if [ "$ONLY" = all ] || [ "$ONLY" = "$n" ]; then
      [ "$active" = 1 ] && { printf '    skip: active account\n'; continue; }
      [ "$start" -ge 0 ] && { printf '    skip: already ticking\n'; continue; }
      ping_account "$n" manual && STARTED=$(( STARTED + 1 ))
    fi
    continue
  fi

  # ---- rails
  # The active account is skipped by default: if its clock is stopped you are
  # about to start it yourself with your next message, and a ping would fix its
  # phase to a moment you did not pick. Set TOKEN_KEEPER_INCLUDE_ACTIVE=1 to
  # treat it like any other - worth it if you often leave it idle for hours.
  if [ "$active" = 1 ] && [ "${TOKEN_KEEPER_INCLUDE_ACTIVE:-0}" != 1 ]; then
    printf '    skip: active account\n'; continue
  fi
  [ "$start" -ge 0 ]  && continue
  [ "$status" != ok ] && { log skip "$n" "usageStatus=$status"
                           printf '    skip: status %s\n' "$status"; continue; }
  if awk -v p="$p7" -v m="$MAX_7D" 'BEGIN { exit !(p >= m) }'; then
    log skip "$n" "7d at ${p7}% >= ${MAX_7D}%"
    printf '    skip: weekly at %s%%\n' "$p7"; continue
  fi
  if [ "${lp:-0}" -gt 0 ] && [ $(( NOW - lp )) -lt "$MIN_GAP" ]; then
    printf '    skip: pinged %s ago, under the %s backstop\n' \
      "$(hhmm $(( NOW - lp )))" "$(hhmm $MIN_GAP)"; continue
  fi

  # ---- placement
  bt=$(best_time "$PHASES")
  wait=$(( bt - NOW ))
  if [ "$wait" -le $(( INTERVAL / 2 )) ]; then
    ping_account "$n" phase && STARTED=$(( STARTED + 1 ))
  else
    printf '    wait %s for phase - would then reset at %s\n' \
      "$(hhmm $wait)" "$(date -d "@$(( bt + W ))" +%H:%M 2>/dev/null)"
    log wait "$n" "$(hhmm $wait)" "target=$(date -d "@$bt" +%H:%M 2>/dev/null)"
  fi
done <<EOF
$(printf '%s' "$ROWS")
EOF

exit 0
