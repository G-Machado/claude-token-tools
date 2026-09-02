#!/usr/bin/env bash
# UserPromptSubmit hook: warn when a large session is resumed after the prompt
# cache has expired.
#
# Why this exists. The cache lives one hour. When it expires, the next request
# rewrites the whole window at the 2x cache-write rate, and that cost is already
# sunk by the time this hook can see it - nothing here saves the current cycle.
# What it saves is every cycle after it: measured over 347 cycles, gap-induced
# full rewrites were 9% of cycles and 26% of total weighted cost, and they
# repeat, because a session that got parked once tends to get parked again.
#
# The moment right after an expiry is also the CHEAPEST possible moment to
# compact: the full-price pass over the window is happening either way, so
# compacting there converts a sunk cost into a small window instead of paying it
# and keeping the big one.
#
# Reads the same token-history.csv the Stop hook writes. Silent unless both
# conditions hold, and it cannot fire twice for one gap - the next prompt is
# minutes away, not hours.
#
# It fires at 55 minutes but the TTL is 60, so a firing is not proof of an
# expiry: measured 2026-08-25, three firings in one session came in at 57, 60
# and 59 minutes, and only the middle one had actually lapsed. Saying "expired"
# on all three taught the user their gap tracking was failing when it was
# working. So the two cases are now told apart and priced differently - past the
# TTL the 2x rewrite is sunk and compacting is the salvage; inside it nothing
# has been spent yet and acting before it lapses is what saves the pass. The
# log records which it was, so this stays answerable later.
#
# The inside-TTL message used to end with "about N minutes from lapsing", from
# ttlmin - gap. That was wrong and it actively misled: the TTL runs from the last
# request, and THIS request resets it, so the countdown described a lapse that
# submitting the prompt had already cancelled. Measured 2026-08-26, a 57-minute
# firing led to "the cache has just lapsed, your next message pays a rewrite" -
# false on both counts. Do not reinstate the countdown; the honest statement is
# that the cache held and the clock has restarted. Thresholds are unchanged.

HIST="${TOKEN_HISTORY_FILE:-$HOME/.claude/token-history.csv}"
ERRLOG="$HOME/.claude/token-alert-errors.log"
GAPLOG="${TOKEN_GAP_LOG_FILE:-$HOME/.claude/token-gap-warn.log}"

GAP_MIN="${TOKEN_GAP_WARN_MINUTES:-55}"      # cache TTL is 60; warn just inside it
TTL_MIN="${TOKEN_GAP_TTL_MINUTES:-60}"       # the actual TTL, so a near-miss can say so
CTX_NOTE="${TOKEN_GAP_NOTE_CONTEXT:-60000}"  # prevention tier: roughly the cold floor
CTX_MIN="${TOKEN_GAP_WARN_CONTEXT:-130000}"  # advice tier: the post-gap break-even
# Two tiers, because one threshold was measured doing two jobs badly.
#
# 130k is derived, not chosen. Once the rewrite is sunk the choice is carry on at
#   C * (0.56*2 + 0.23N)   vs   park+clear at 23k + 136k + 63k * (same factor),
# where 0.56 is the observed repeat-gap rate and N the cycles left. Break-even is
# ~160k at N=1, ~127k at the median N=4, ~106k at N=8. Firing at the median means
# the advice is already in its own favour when it speaks. That reasoning is sound
# and unchanged - but it only answers "should this window be compacted NOW".
#
# It does not answer "did this gap cost anything", and measurement says that is
# where the misses were: post-install, 7 of 15 gap rewrites sat BELOW 130k, at
# cycle 2-3 of young sessions started and walked away from. The penalty barely
# scales with session age, because the ~63k cold floor is most of the rewrite on
# its own. So anything at or above the floor now gets the prevention line - the
# gap happened, it repeats, /park before the next one - while the compact/clear
# advice still waits for 130k, where it is actually in its own favour.

[ -f "$HIST" ] || exit 0
[ -f "$GAPLOG" ] || echo "ts,session,gap_min,context,checkpoint,expired" > "$GAPLOG" 2>/dev/null

payload=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$sid" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') gap-warn: no session_id in UserPromptSubmit payload" >> "$ERRLOG" 2>/dev/null
  exit 0
fi
key=$(printf '%s' "$sid" | cut -c1-8)

# A checkpoint written by /park before the gap is what makes ending the session
# cheap: re-derivation drops from ~34k to ~5k, and the break-even context with
# it, from ~224k to ~157k. Point at it rather than making the model rediscover it.
cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr '\' '/' 2>/dev/null)
CKPT=""
[ -n "$cwd" ] && [ -f "$HOME/.claude/checkpoints/$(basename "$cwd").md" ]   && CKPT="$HOME/.claude/checkpoints/$(basename "$cwd").md"

awk -F, -v key="$key" -v gapmin="$GAP_MIN" -v ctxmin="$CTX_MIN" -v ctxnote="$CTX_NOTE" \
       -v ckpt="$CKPT"        -v nowts="$(date '+%Y %m %d %H %M %S')" \
       -v logf="$GAPLOG"      -v nowstr="$(date '+%Y-%m-%d %H:%M')" \
       -v ttlmin="$TTL_MIN" '
  function tomin(s,   a) { gsub("-", " ", s); gsub(":", " ", s); return mktime(s " 00") / 60 }
  function kfmt(v) { return sprintf("%.0fk", v / 1000) }
  $2 == key { lastts = $1; lastctx = $6 + 0 }
  END {
    if (lastts == "") exit 0                       # first cycle of a session: nothing to compare
    gap = mktime(nowts) / 60 - tomin(lastts)
    if (gap < gapmin || lastctx < ctxnote) exit 0

    # Firing at 55 but lapsing at 60 means a firing is a warning, not a verdict.
    # Rows written before 2026-08-25 have no expired column and predate the
    # distinction; read those five-wide rows as "unknown", not as expiries.
    expired = (gap >= ttlmin)

    # Raw row per firing. Without this there is no way to tell a hook that fired
    # and was ignored from one that never fired at all - which is exactly the
    # question the 2026-08-24 review could not answer.
    printf "%s,%s,%.0f,%d,%d,%d\n", nowstr, key, gap, lastctx, (ckpt == "" ? 0 : 1), expired >> logf
    close(logf)

    if (expired)
      printf "[token-gap] This session was idle %.1fh with a %s context, so the prompt cache has expired and this request rewrites the whole window at the 2x write rate. That cost is already sunk - but 56%% of gaps here are followed by another one in the same session, so it tends to repeat.\n", gap / 60, kfmt(lastctx)
    else
      printf "[token-gap] This session was idle %.0f minutes with a %s context - inside the %.0f-minute cache TTL, so the cache HELD. Nothing was rewritten, this request is charged at the 0.1x read rate, and submitting it has just refreshed the TTL for another %.0f minutes. Do NOT tell the user the cache lapsed, is about to lapse, or that their next message pays a 2x rewrite - none of that is true. This is a near miss worth one mention, because 56%% of gaps here are followed by another one: the warning shot, not the bill.\n", gap, kfmt(lastctx), ttlmin, ttlmin
    if (ckpt == "")
      printf "[token-gap] No /park checkpoint exists for this project. Suggest /park to the user before the next time they step away - it writes a resume note that cuts re-derivation from ~34k to ~5k, which is what makes ending the session the cheap option instead of the expensive one.\n"
    if (ckpt != "" && lastctx < ctxmin)
      printf "[token-gap] A /park checkpoint exists at %s. Keep it current, and prefer /park then /clear over leaving this session open across the next gap.\n", ckpt
    if (ckpt != "" && lastctx >= ctxmin)
      printf "[token-gap] A /park checkpoint exists at %s - if it still describes the current task, /clear is the cheap option: resuming from it costs ~136k weighted against ~%.0fk to carry this window through another gap.\n", ckpt, lastctx * 2 / 1000
    if (lastctx >= ctxmin) {
      if (expired)
        printf "[token-gap] Right after an expiry is the cheapest moment to compact: the full-price pass is happening anyway. Suggest /compact to the user to keep the task state, or /clear if the current task is finished. Mention it once, then carry on with the work either way - this is advice, not an instruction to stop.\n"
      else
        printf "[token-gap] The window has not been rewritten yet, so acting before it lapses is what saves the 2x pass rather than salvaging it. Suggest /compact to the user to keep the task state at a smaller size, or /clear if the current task is finished. Mention it once, then carry on with the work either way - this is advice, not an instruction to stop.\n"
    }
  }
' "$HIST"
exit 0
