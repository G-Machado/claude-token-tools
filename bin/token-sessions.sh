#!/usr/bin/env bash
# Live view of every Claude Code session on this machine: how big each window
# is, how much prompt-cache life it has left, and what to do about it.
#
# Why. The status line only knows the session it is drawn in, but the expensive
# failure here is cross-session: 59% of measured gap-rewrites had ANOTHER of the
# user's own sessions active during the idle window. The window you cannot see
# is the one costing money.
#
# Costs no model tokens - every number comes off disk:
#   sessions/<pid>.json      pid -> sessionId, cwd, name   (written by the CLI)
#   projects/*/<sid>.jsonl   transcript; its mtime is last activity, and its
#                            first human turn is the session's real title
#   token-history.csv        context per cycle, from the Stop hook. Its last row
#                            for a session is when that session last STOPPED, so
#                            a transcript newer than it means a turn is in flight
#   token-titles.tsv         sid -> title cache (this script; a first turn never
#                            changes, so it is only ever extracted once)
#   checkpoints/<proj>.<topic>.md
#                            /park output, one file per topic. Matched to a
#                            session by the session= stamp /park writes into it,
#                            and by mtime for older unstamped files
#
# Usage:
#   token-sessions.sh                 one snapshot, live sessions only
#   token-sessions.sh --watch [secs]  live pane, redraws in place (default 60s)
#   token-sessions.sh --browse        live pane, opened on the detail panel
#   token-sessions.sh --analytics     history: where the spend went, and whether
#                                     it is getting better
#   token-sessions.sh --weekly        analytics in weeks rather than days
#   token-sessions.sh --all           include sessions whose process is gone,
#                                     newest TOKEN_CLOSED_MAX of them (12)
#   token-sessions.sh --compact       one line per session, no titles
#   token-sessions.sh --sort NAME     lapse (default), context, cost, active or
#                                     project; s cycles the same list in the pane
#   token-sessions.sh --filter TEXT   only sessions whose name, project, opening
#                                     prompt or path contains TEXT
#   token-sessions.sh --checkpoints [proj]
#                                     what is parked, newest first (default: the
#                                     project in the cwd; "all" for every one)
#   token-sessions.sh --classic       the older rounded frame and softer palette
#   token-sessions.sh --ascii         no box-drawing or block glyphs
#   token-sessions.sh --no-color      plain text
#   token-sessions.sh --version       what this copy is, and what is available
#   token-sessions.sh --update        pull and reinstall from the clone
#   token-sessions.sh --no-update-check   skip the once-a-day version check
#   token-sessions.sh --help          this block
#
# The keys for --watch / --browse are printed at the end of this block, from the
# same table the pane draws its own footer and ? overlay from - so a key cannot
# work while being documented nowhere, which is what happened to d, D, g and G.
#
# Two of them are worth calling out because they are what the pane could not do
# before: / narrows the list to a name, project, prompt or path, and s re-orders
# it (lapse, context, cost, active, project). Both are view state - they rewrite
# view of the snapshot rather than re-reading the disk, so they land on the next
# redraw and cost nothing.
#
# What / opens is a small command line rather than only a filter box, because a
# second prompt key would be one more thing to find. A line starting with "n"
# names the selected row instead of searching: "/n build-fix" calls that row
# build-fix until you say otherwise, blanks inside a name become dashes so it
# stays one token, and a bare "/n" hands the row back to the name derived from
# its own prompts. A typed name outranks every re-roll variant, and n clears it.
# To filter for the letter n itself, type "/ n" - the space is what says search. y puts "claude -r <id>" on the clipboard and o opens
# the checkpoint behind the selected row, because every piece of advice here
# ends in something you have to go and do somewhere else.
#
# Nothing is computed and then discarded. The analytics tab used to shed eight
# of its eleven sections in a short window and advise a taller one; it now runs
# over as many pages as it needs and [ ] walks them. The session list scrolls
# rather than truncating, so every row is reachable however short the terminal.
# A one-shot --analytics prints the lot: it goes to a scrollback, not a pane.
#
# The bell: in --watch, a window inside TOKEN_BELL_MIN minutes (5) of losing its
# prompt cache rings the terminal once, provided it is big enough for the lapse
# to cost more than acting on it would. One ring per session per lapse, and it
# re-arms when that window goes warm again. TOKEN_BELL=0 silences it for good.
#
# The one network call: once a day, detached, with a 4-second timeout, this asks
# GitHub what the latest released version is and writes the answer to
# token-version.state. If it is newer than this copy the pane offers it in the
# footer - u takes it (git pull in the clone install.sh recorded, then that
# installer again), U dismisses it for the run. Nothing is ever downloaded
# without that keypress, every failure is silent, and TOKEN_UPDATE_CHECK=0 turns
# the whole thing off. A one-shot run has no keys, so it only says so.
#
# There is no auto-renewal here and deliberately never will be. A print-mode
# ping shares only ~18.7k of system prompt with an interactive session, so it
# refreshes a prefix the live session never sends - measured against both a
# VS Code and a plain terminal parent, the same 18,690 either way. The write-up
# is in token-failsafe-findings.md. What replaced it is a louder warning: the
# bell above plus a desktop notification (TOKEN_POPUP=0 silences it), so a gap
# gets acted on before it opens instead of paid for after. Acting was always the
# cheaper move; the pinger was trying to remove the need to and could not.
#
# Row markers:  a moving bar = a turn is running right now (a solid arrow in the
# one-shot form, which has no second frame to animate into), a hollow arrow =
# the session touched most recently; a diamond = a /park checkpoint is on disk
# for this window. While anything is running the pane redraws four times a
# second and re-reads the disk every ten, so the marker cannot go on moving for
# a turn that has already finished.
#
# The second glyph on every row is the VERDICT - what to do with that window,
# off the same ladder the advice underneath is written from. A filled triangle
# means act now (it is cold above the clear-vs-carry bar, or warm and about to
# lapse with enough in it to be worth parking); a hollow one means a cut would
# pay if you want it; a ring means there is nothing to decide, which is most
# rows most of the time and is drawn dim so it recedes.
#
# Columns:
#   context  length AND colour are both size, and nothing else: dim green under
#            the ~63k floor (a fresh session would start bigger), green under
#            the parking bar, yellow past it, orange once a cut would pay with a
#            checkpoint on disk, red once it would pay without one. What the
#            window costs RIGHT NOW depends on the cache, and that lives in the
#            cache column and the advice line - it used to be mixed into this
#            colour, which made a row change colour without changing size.
#   cost     what the session has spent so far, in input-equivalents (output x5,
#            cache write x2, cache read x0.1). The bar splits it three ways:
#            green output, orange cache writes, blue cache reads. More green is
#            better - it is the share that went into doing the work rather than
#            into paying rent on a window. Cache reads are MODELLED (context x
#            2.3 requests per cycle), not measured; everything else is counted.
#            Select the row for the same split with the figures beside it.
#   growth   one glyph per cycle, up to twelve, height on a fixed scale so the
#            column means the same thing on every row: how much NEW material
#            that cycle pulled in. Red over the growth budget, amber over the
#            output budget. Select the row for med / last / peak.
#   grade    spend / production / control for that session, against what this
#            machine actually does. Spend is measured ABOVE the ~63k cold floor,
#            because that write is not a choice - undiscounted it ran 254k per
#            cycle at cycle 1 and decayed to 168k by cycle 8 on identical work,
#            which was a whole letter of penalty for being young. The same
#            three, aggregated over the last seven days, sit under the summary
#            box as OVERALL - that line is the one to watch across weeks.
#   cache    minutes of prompt-cache life left, and nothing else. It used to
#            draw a bar beside the number, which is two renderings of one
#            scalar taking the width of a real column; the number is the half
#            you act on, so the bar went and the columns it freed went to the
#            cost split and the growth trend.

set -u
# Byte semantics, pinned, and not a stylistic choice - the whole file depends on
# it in two ways that only diverge once a locale is set:
#
#   - awk's length()/substr()/index() count BYTES in the C locale and CHARACTERS
#     in a UTF-8 one. Every column here is padded by hand around three-byte
#     glyphs on the byte assumption (see pad(), spark(), gcell()), so a UTF-8
#     locale silently shifts the layout of every row;
#   - a bracket range over high bytes - [\200-\277], which is how dwid() finds
#     UTF-8 continuation bytes to measure display width - is a COLLATION range.
#     In the C locale it means those byte values. Under a UTF-8 locale gawk
#     rejects it outright: "Invalid collation character", fatal, on the first
#     frame drawn.
#
# The second is why this line exists. An interactive shell here usually carries
# no LANG at all, so the pane worked; the desktop shortcut runs a LOGIN shell,
# the profile sets one, and the program died before it could paint anything.
export LC_ALL=C
# The renderers are single-quoted awk programs, so an apostrophe ANYWHERE inside
# one - in a comment as readily as in a string - closes the quote and hands the
# rest of the program to bash. It fails as a shell syntax error hundreds of
# lines away from the line that caused it, which is why every comment in here
# says "the panel" and not "the panel's". Same for the analytics program and
# frame_blocks. bash -n catches it instantly; nothing else will.
CL="$HOME/.claude"
HIST="$CL/token-history.csv"
TITLES="$CL/token-titles.tsv"
META="$CL/token-meta.tsv"                # sid -> mtime, last activity, cwd
# What version this copy is, where to ask whether there is a newer one, and
# where the answer is remembered between runs. The check is the only thing in
# this program that touches the network, and it is built so that it cannot cost
# you anything you did not ask for: it runs detached with a 4-second timeout, it
# runs at most once a day, it writes one small file, and every failure - no
# curl, no network, a rate-limited CDN, a garbage answer - is silent and leaves
# the previous answer in place. TOKEN_UPDATE_CHECK=0 turns it off for good.
TSVER="1.0.0"
UPDREPO="${TOKEN_UPDATE_REPO:-G-Machado/claude-token-tools}"
UPDBRANCH="${TOKEN_UPDATE_BRANCH:-master}"
UPDSTATE="$CL/token-version.state"       # last check epoch <TAB> version seen
SRCFILE="$CL/token-tools-src"            # the clone install.sh came from
UPDCHECK="${TOKEN_UPDATE_CHECK:-1}"      # 0 disables the check entirely
UPDEVERY="${TOKEN_UPDATE_EVERY:-86400}"  # seconds between checks
NICKS="$CL/token-nicks.tsv"              # sid -> re-roll variant, and the name
                                         # typed with /n if there is one
PROJMAP="$CL/token-projmap.tsv"          # short sid -> project label, for the analytics tab
FSFORKS="$CL/token-failsafe-forks.txt"   # short sids of ping forks, kept out of the history
NVAR="${TOKEN_NICK_VARIANTS:-6}"         # re-rolls before n comes back to the default
CLOSED_MAX="${TOKEN_CLOSED_MAX:-12}"     # closed sessions listed by --all; the
                                         # rest are counted in a footer
CK_STALE="${TOKEN_PARK_STALE:-15}"       # minutes of work AFTER a /park before
                                         # its checkpoint counts as behind. Not 0:
                                         # parking and then sending one more
                                         # message has not invalidated anything
SHOW_OLL="${TOKEN_SHOW_OLLAMA:-0}"       # 1 puts the local-runtime lines back in
                                         # the sessions pane; they are off by
                                         # default because a free runtime has
                                         # nothing to report in a block whose
                                         # subject is what is being paid for.
                                         # This is the only place they appear
BELL="${TOKEN_BELL:-1}"                  # 0 silences the lapse bell
BELL_MIN="${TOKEN_BELL_MIN:-5}"          # minutes of cache life left that rings it
POPUP="${TOKEN_POPUP:-1}"                # desktop notification alongside the bell
TTL="${TOKEN_CACHE_TTL_MIN:-60}"
CTXMAX="${TOKEN_CTX_FULL_K:-300}"        # context bar full-scale, thousands
OBUD="${TOKEN_ALERT_BUDGET:-20000}"      # output budget per cycle, for the trend colour
GBUD="${TOKEN_GROWTH_BUDGET:-25000}"     # growth budget per cycle, for the trend scale
RPC="${TOKEN_REQ_PER_CYCLE:-2.3}"        # requests per cycle, for the modelled cache reads
PRICE_IN="${TOKEN_PRICE_IN:-5}"          # $/MTok input, Opus 5 list. Everything else
                                         # here is a multiple of it: output x5,
                                         # cache write x2, cache read x0.1.
# The plan ceilings cannot be read off disk - nothing under ~/.claude records
# them, and /usage fetches them from the API. So they are calibrated by hand,
# once: run /usage in Claude Code, read the percentage it reports, and set the
# ceiling so this agrees. Left at 0 the analytics tab shows the spend without a
# percentage rather than inventing a limit.
PLAN_5H="${TOKEN_PLAN_5H_USD:-0}"        # $ of API-equivalent spend per 5h window
PLAN_WK="${TOKEN_PLAN_WEEK_USD:-0}"      # $ of API-equivalent spend per week

# The history, minus the cycles the fail-safe's own pings wrote. Nothing to do
# in the ordinary case, and the ordinary case is checked first.
hist_rows() {
  if [ -s "$FSFORKS" ]; then
    awk -F, 'NR == FNR { skip[$1] = 1; next } !($2 in skip)' "$FSFORKS" "$HIST"
  else
    cat "$HIST"
  fi
}

# Short sid -> project, for the analytics tab. The history CSV carries no
# project column and never will - the Stop hook writes one row per cycle and
# knowing where it ran is not its job - but the transcripts are already filed
# under a directory named for the cwd they were opened in, so the mapping is
# recoverable from the glob for free. Keyed on the same 8 characters the
# history uses.
#
# Cached, because the analytics tab redraws every second in watch mode and this
# is a directory listing of every transcript on the machine. Regenerated when
# the cache is missing or older than the refresh below; a session that opens
# mid-frame simply lands in the map on the next sweep, which for a per-project
# spend total is not a distinction worth a stat call per frame.
#
# Decoding the directory name is best-effort by construction: the encoder
# replaced every separator with a hyphen, so a project whose own name contains
# one is no longer distinguishable from a path boundary. What IS reliable is
# the head of the path, which is why this drops known-boring leading segments
# rather than trying to find the last one - "Users" plus the username that
# follows it, then the containers people keep code in. Whatever survives is the
# label, and a path that reduces to nothing was the home directory itself.
proj_rows() {
  local age=0
  if [ -f "$PROJMAP" ]; then
    age=$(( $(now_s) - $(stat -c %Y "$PROJMAP" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt 300 ] && { cat "$PROJMAP"; return 0; }
  fi
  ls -1 "$CL"/projects/*/*.jsonl 2>/dev/null | awk -F/ '
    function projlabel(d,   n, a, i, out) {
      sub(/^[A-Za-z]--/, "", d)
      n = split(d, a, "-")
      i = 1
      while (i <= n) {
        # Users/<name> and home/<name> consume two segments, not one.
        if (a[i] == "Users" || a[i] == "home") { i += 2; continue }
        if (a[i] == "Documents" || a[i] == "UnityProjects" || a[i] == "Projects" || \
            a[i] == "projects" || a[i] == "source" || a[i] == "repos" || \
            a[i] == "src" || a[i] == "dev" || a[i] == "code" || \
            a[i] == "git" || a[i] == "workspace") { i++; continue }
        break }
      for (; i <= n; i++) out = out (out == "" ? "" : "-") a[i]
      return (out == "") ? "~" : out }
    NF > 1 { print substr($NF, 1, 8) "\t" projlabel($(NF - 1)) }' \
    | sort -u > "$PROJMAP.$$" 2>/dev/null
  if [ -s "$PROJMAP.$$" ]; then mv -f "$PROJMAP.$$" "$PROJMAP"; else rm -f "$PROJMAP.$$"; fi
  cat "$PROJMAP" 2>/dev/null
}

# The floor and the re-derivation cost set the price of every restart, and both
# are measurable from the history rather than remembered from a review. Measured
# once at startup, never per frame.
#
# The basis matters and used to be wrong: re-derivation is what a RESUMING
# session holds above what a FRESH one holds, so both sides have to be medians
# of the same statistic. Measuring it above the *minimum* cold start (as
# --stats did) counts the gap between the minimum and the median twice and
# inflates the number roughly threefold.
measure_constants() {
  M_FLOOR=0; M_RD=0; M_CPS=0
  [ -r "$HIST" ] || return 0
  M_WPC=0; M_PROD=0; M_REM=0; M_HEAT=0
  read -r M_FLOOR M_RD M_CPS M_WPC M_PROD M_REM M_HEAT <<< "$(awk -F, \
      -v gap="${TOKEN_CONTINUATION_GAP:-30}" -v rpc="$RPC" '
    function tomin(t,   a, d, h) {
      split(t, a, " "); split(a[1], d, "-"); split(a[2], h, ":")
      return ((d[1] * 365 + d[2] * 31 + d[3]) * 24 + h[1]) * 60 + h[2] }
    function med(v, m,   i, j, t) {
      if (m < 1) return 0
      for (i = 2; i <= m; i++) { t = v[i]; for (j = i - 1; j >= 1 && v[j] > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
      return (m % 2) ? v[int(m / 2) + 1] : (v[m / 2] + v[m / 2 + 1]) / 2 }
    NR > 1 && $2 != "" {
      cyc++
      # Per-session totals, for the scorecard medians. Weighted the same way
      # everywhere: output x5, cache write x2, cache read x0.1 per request.
      sn[$2]++; so[$2] += $4; sr[$2] += $5; if ($6 + 0 > sc[$2]) sc[$2] = $6 + 0
      # Rent against work, in 25k bands of window size. Rent is what a cycle
      # pays purely to have this window in front of it (the modelled cache
      # reads); work is what it produced. Where the first overtakes the second
      # the window has stopped earning its keep - see the crossover below.
      bi = int($6 / 25000)
      hr[bi] += $6 * rpc * 0.1; hw[bi] += $4 * 5; hn[bi]++
      if ($3 + 0 == 1) {
        ses++
        # A session opening within `gap` minutes of the last recorded cycle
        # anywhere is resuming work, not starting it - so what it carries at
        # the end of cycle 1 is the floor plus catching up.
        if (prev != "" && tomin($1) - prev <= gap) rv[++rn] = $6 + 0
        else                                      fv[++fn] = $6 + 0 }
      prev = tomin($1) }
    END {
      # Under this many samples a median is a single observation wearing a hat,
      # and this term swings every band - so fall back to the literals instead.
      if (fn < 5 || rn < 5 || ses < 2) { print "0 0 0 0 0"; exit }
      f = med(fv, fn); r = med(rv, rn) - f; if (r < 0) r = 0
      # How many cycles a window still has left in it. NOT the same question as
      # cycles-per-session, which is what the cut bars used to be built on, and
      # the difference is not small: every position in every session contributes
      # one observation here, so a 40-cycle session says "39 left" once and "0
      # left" once rather than voting 40 times for its own length. Measured 4,
      # against the 7.1 cycles-per-session that stood in for it - which is why
      # the cut bars used to sit ~80k below where the arithmetic puts them.
      rmn = 0
      for (k in sn) for (q = 0; q < sn[k]; q++) rmv[++rmn] = sn[k] - 1 - q
      rem = med(rmv, rmn)
      # The overheat bar: the window size at which rent overtakes work. Walked
      # from the floor upward, because the bottom band is all short sessions
      # whose output has not started yet and whose ratio is near 1 for reasons
      # that have nothing to do with a window being too big - starting the walk
      # at the bottom would find that instead and report a crossover of 40k.
      heat = 0; pm2 = 0; pr2 = 0
      for (b = int(f / 25000) + 1; b <= 40; b++) {
        if (hn[b] < 5 || hw[b] <= 0) continue
        rr = hr[b] / hw[b]; mid = (b + 0.5) * 25
        if (pm2 > 0 && pr2 < 1 && rr >= 1) { heat = pm2 + (mid - pm2) * (1 - pr2) / (rr - pr2); break }
        pm2 = mid; pr2 = rr }
      for (k in sn) {
        if (sn[k] < 2) continue
        w = so[k] * 5 + sr[k] * 2 + sc[k] * 2.3 * 0.1 * sn[k]
        if (w <= 0) continue
        # Above the floor, not from zero. Every session pays ~f of cache write
        # before it has done anything, and dividing that one-off by a small
        # cycle count is why a two-cycle session used to grade a whole letter
        # worse than identical work at cycle ten. Measured over 91 sessions the
        # raw figure ran 254k/cycle at cycle 1 and decayed to 168k by cycle 8;
        # discounted it sits at 135-150k throughout. The 15% clamp keeps a
        # session that never grew past the floor from grading on a negative.
        d = w - f * 2; if (d < w * 0.15) d = w * 0.15
        wv[++wn] = d / sn[k] / 1000
        pv2[wn]  = so[k] * 5 * 100 / w }
      printf "%.1f %.1f %.2f %.0f %.0f %.1f %.0f\n", f / 1000, r / 1000, cyc / ses, \
        (wn ? med(wv, wn) : 0), (wn ? med(pv2, wn) : 0), rem, heat }' <(hist_rows) 2>/dev/null)"
  : "${M_FLOOR:=0}" "${M_RD:=0}" "${M_CPS:=0}" "${M_WPC:=0}" "${M_PROD:=0}"
  : "${M_REM:=0}" "${M_HEAT:=0}"
}
measure_constants

# The same three axes the per-session grade uses, aggregated over a recent
# window and the one before it, so the sessions tab can carry an OVERALL line
# that moves week to week. Graded in render against the SAME corpus medians a
# single session is graded against - otherwise a row could read B while the
# overall read D on identical numbers.
#
# Cache reads are modelled here per ROW (that row's context x requests/cycle)
# rather than per session, which is the more honest of the two: a session-level
# estimate charges cycle 1 for the window cycle 40 ended up with.
measure_overall() {
  O_WPC=0; O_PROD=0; O_CTL=0; O_N=0; P_WPC=0; P_PROD=0; P_CTL=0; P_N=0
  O_5H=0; O_7D=0
  [ -r "$HIST" ] || return 0
  read -r O_WPC O_PROD O_CTL O_N P_WPC P_PROD P_CTL P_N O_5H O_7D <<< "$(awk -F, \
    -v now="${EPOCHSECONDS:-$(date +%s)}" -v rpc="$RPC" -v floor="$M_FLOOR" '
    function ep(t,   s) { s = t; gsub(/[-:]/, " ", s); return mktime(s " 00") }
    NR > 1 && $2 != "" {
      e = ep($1); if (e <= 0) next
      g = (($2 in pv) ? $6 - pv[$2] : 0); if (g < 0) g = 0
      ch = $5 - g; if (ch < 0) ch = 0
      pv[$2] = $6
      w = $4 * 5 + $5 * 2 + $6 * rpc * 0.1
      # The floor lands entirely on cycle 1, so that is the only row it is
      # discounted off - see the note in measure_constants. Graded on the same
      # basis as a single session, or the OVERALL line and a row cell would be
      # two different claims about the same numbers.
      wg = w
      if ($3 + 0 == 1 && floor > 0) { wg = w - floor * 2000; if (wg < w * 0.15) wg = w * 0.15 }
      # Control counts a gap rewrite double: a breach is one prompt that asked
      # for too much, a rewrite is a whole window paid for twice.
      bad = (($7 != "-" && $7 != "") ? 1 : 0) + (($3 + 0 > 1 && ch > 60000) ? 2 : 0)
      age = now - e
      if      (age <= 604800)  { rw += wg; ru += w; ro += $4 * 5; rn++; rc += bad }
      else if (age <= 1209600) { qw += wg; qu += w; qo += $4 * 5; qn++; qc += bad }
      else                     { xw += wg; xu += w; xo += $4 * 5; xn++; xc += bad }
      if (age <= 604800) s7 += w
      if (age <= 18000)  s5 += w }
    END {
      # A quiet fortnight leaves the prior week too thin to compare against, so
      # it widens to everything older rather than reporting a swing measured
      # off two cycles.
      if (qn < 5) { qw += xw; qu += xu; qo += xo; qn += xn; qc += xc }
      # Spend off the discounted weight, production off the real one. They are
      # two different questions: how hard the window was driven above a floor it
      # had no say in, versus what share of every token actually spent went into
      # work. Rebasing the second measured flat across cycle index (35% at cycle
      # 1, 35% at cycle 8), so there was nothing there to correct and correcting
      # it anyway would just have inflated the number.
      printf "%.1f %.0f %.3f %d %.1f %.0f %.3f %d %.0f %.0f\n", \
        (rn ? rw / rn / 1000 : 0), (ru ? ro * 100 / ru : 0), (rn ? rc / rn : 0), rn, \
        (qn ? qw / qn / 1000 : 0), (qu ? qo * 100 / qu : 0), (qn ? qc / qn : 0), qn, \
        s5 / 1000, s7 / 1000 }' <(hist_rows) 2>/dev/null)"
  : "${O_WPC:=0}" "${O_PROD:=0}" "${O_CTL:=0}" "${O_N:=0}"
  : "${P_WPC:=0}" "${P_PROD:=0}" "${P_CTL:=0}" "${P_N:=0}" "${O_5H:=0}" "${O_7D:=0}"
}
measure_overall

# The local-model ledger, the mirror of measure_overall. Ollama generation is free (no
# Anthropic tokens), so what matters is the 7d offload ratio: local generated tokens
# against the sum of local + Claude output over the same window. Reads ollama-usage.csv,
# written one row per call by ollama-run.sh, and the same token-history.csv column 4
# (Claude output) the OVERALL line grades on - so the two lines mean the same thing by
# "generation". Costs one awk over each file, nothing if neither exists.
measure_ollama() {
  OLL_PROMPT=0; OLL_EVAL=0; OLL_CALLS=0; CL_OUT_7D=0
  OLOG="$CL/ollama-usage.csv"
  if [ -r "$HIST" ]; then
    CL_OUT_7D="$(awk -F, -v now="${EPOCHSECONDS:-$(date +%s)}" '
      function ep(t,   s) { s = t; gsub(/[-:]/, " ", s); return mktime(s " 00") }
      NR > 1 && $1 != "" { e = ep($1); if (e > 0 && now - e <= 604800) o += $4 }
      END { printf "%d", o + 0 }' <(hist_rows) 2>/dev/null)"
  fi
  if [ -r "$OLOG" ]; then
    read -r OLL_PROMPT OLL_EVAL OLL_CALLS <<< "$(awk -F, -v now="${EPOCHSECONDS:-$(date +%s)}" '
      function ep(t,   s) { s = t; gsub(/[-:]/, " ", s); return mktime(s " 00") }
      NR > 1 && $1 != "" { e = ep($1); if (e > 0 && now - e <= 604800) { p += $4; v += $5; c++ } }
      END { printf "%d %d %d", p + 0, v + 0, c + 0 }' "$OLOG" 2>/dev/null)"
  fi
  : "${OLL_PROMPT:=0}" "${OLL_EVAL:=0}" "${OLL_CALLS:=0}" "${CL_OUT_7D:=0}"
}
measure_ollama

# The same log, per session rather than summed. The aggregate line answers "how
# much of the generation went local"; it cannot answer "which of these was the
# benchmark and when did it last run", which is the question you ask the moment
# there is more than one. Same shape as a Claude row - who, how much, how
# recently - because it is the same question one runtime over.
ollama_sessions() {
  [ -r "$CL/ollama-usage.csv" ] || return 0
  awk -F, -v now="${EPOCHSECONDS:-$(date +%s)}" '
    function ep(t,   s) { s = t; gsub(/[-:]/, " ", s); return mktime(s " 00") }
    NR > 1 && $2 != "" {
      e = ep($1); if (e <= 0) next
      k = $2
      C[k]++; P[k] += $4; V[k] += $5; MS[k] += $6
      if (e >= L[k]) { L[k] = e; M[k] = $3; T[k] = $7 } }
    END {
      for (k in C)
        printf "%d|%s|%d|%s|%d|%d|%d|%s\n", \
          ((now - L[k] < 0) ? 0 : now - L[k]), k, C[k], M[k], P[k], V[k], MS[k] / C[k], T[k] }' \
    "$CL/ollama-usage.csv" 2>/dev/null | sort -t'|' -k1,1n
}
OLL_SESSIONS="$(ollama_sessions)"

# The bell's floor, in thousands: the parking bar, which is where a lapse first
# costs more than doing something about it would. Derived from the measured
# floor exactly as the renderer derives its own PARK_AT, so the bell and the
# colour it is warning about can never disagree - RD_PARK is 5 and half of the
# ~23k a /park itself costs rounds to 12.
# Truncated first: the measured floor is a median and carries a decimal, which
# bash arithmetic will not take.
BELL_CTX=${M_FLOOR%%.*}
BELL_CTX=$(( ${BELL_CTX:-0} > 0 ? BELL_CTX + 17 : 80 ))

# The view state: which order the rows are in, and which of them are showing.
#
# Both live HERE rather than in collect(), because neither is data - they are
# how you are looking at the data, and re-collecting to change a sort would put
# a disk read behind a keystroke. arrange() rewrites the snapshot into a view
# file, so every consumer that addresses a row by its number (render, delete,
# copy, open) is reading the same order you are looking at.
SORTS=(lapse context cost active project)
# Both take an environment default so the desktop shortcut can open on the view
# you actually want - token-sessions-launch.sh is where that belongs - and so
# the one-shot form can be asked the same questions the pane can.
SORT="${TOKEN_SORT:-0}"
SORTNAME=""
FILTER="${TOKEN_FILTER:-}"
ARRDIRTY=1

# One key table, three consumers: the footer strip, the ? overlay, and --help.
# They used to be three hand-maintained lists and they disagreed - d, D, g and G
# worked while appearing in none of the documentation, w and b were in the
# header block but not the footer, and the comment above the c handler described
# a feature that no longer exists. Fields: key | what it does | footer label,
# and an empty third field keeps a key out of the footer without hiding it.
KEYTAB='j k|move the selection, or scroll the list|move
1-9|jump to a row - type two digits past nine|jump
g G|first row / last row|
/|filter by name, project, prompt or path|filter
/n|"/n build-fix" names the selected row; bare /n undoes it|
s|re-order: lapse, context, cost, active, project|sort
d|expand the selected row into the full panel|expand
y|copy "claude -r <id>" to the clipboard|copy
o|open the checkpoint, or the transcript folder|open
n|re-roll this row name, or clear one typed with /n|rename
D|move a closed session log to deleted-sessions|delete
t|analytics: the whole history|analytics
[ ]|analytics: page through the sections|
w|analytics: daily or weekly buckets|
a|include closed sessions|all
c|compact rows, drop the prompt titles|compact
u U|take an offered update, or dismiss the offer|
b|mute or unmute the lapse bell|
r|collect now rather than on the clock|refresh
esc|back one step|back
?|this list, and the column key|keys
q|quit|quit'

# The header block is the help text - one copy, so a flag cannot go undocumented
# while still working.
show_help() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  # The keys come off KEYTAB rather than out of the header block, so --help and
  # the pane cannot disagree about what a key does.
  printf 'Keys in --watch / --browse:\n'
  printf '%s\n' "$KEYTAB" | awk -F'|' '{ printf "  %-5s %s\n", $1, $2 }'
}

SHOW_ALL=0; WATCH=0; EVERY=60; ASCII=0; COLOR=1; SEL=0; COMPACT=0
CKLIST=0; CKPROJ=""; ANALYTICS=0; BADARG=""; BUCKET=0
VERSIONQ=0; UPDATEQ=0
THEME="${TOKEN_THEME:-hud}"          # hud or classic; --classic switches back
[ -n "${NO_COLOR:-}" ] && COLOR=0

want_proj=0; want_sort=0; want_filter=0
for a in "$@"; do
  if [ "$want_proj" = 1 ]; then want_proj=0
    case "$a" in --*) ;; *) CKPROJ="$a"; continue ;; esac
  fi
  if [ "$want_sort" = 1 ]; then want_sort=0
    case "$a" in --*) ;; *) TOKEN_SORT_NAME="$a"; continue ;; esac
  fi
  if [ "$want_filter" = 1 ]; then want_filter=0
    case "$a" in --*) ;; *) FILTER="$a"; continue ;; esac
  fi
  case "$a" in
    --all|-a) SHOW_ALL=1 ;; --watch|-w) WATCH=1 ;; --ascii) ASCII=1 ;;
    --browse|-b) WATCH=1; SEL=1; DETAIL=1 ;; --compact|-c) COMPACT=1 ;;
    --analytics|--history|-t) ANALYTICS=1 ;;
    --weekly) BUCKET=1 ;; --daily) BUCKET=0 ;;
    --classic) THEME=classic ;; --hud) THEME=hud ;;
    # Both exit rather than drawing anything: they are questions about the
    # program, not about the sessions.
    --version|-V) VERSIONQ=1 ;;
    --update) UPDATEQ=1 ;;
    --no-update-check) UPDCHECK=0 ;;
    --checkpoints|--parked) CKLIST=1; want_proj=1 ;;
    # The two view controls, as flags as well as keys, so a shortcut or a script
    # can open straight on the question it is asking.
    --sort) want_sort=1 ;;
    --sort=*) TOKEN_SORT_NAME="${a#*=}" ;;
    --filter) want_filter=1 ;;
    --filter=*) FILTER="${a#*=}" ;;
    --no-color) COLOR=0 ;;
    --help|-h) show_help; exit 0 ;;
    [0-9]*) EVERY="$a" ;;
    # Silently ignoring a typo is how you end up believing --no-colour works.
    *) BADARG="$BADARG $a" ;;
  esac
done
# Named rather than numbered, because --sort 2 is not a thing anyone can read.
if [ -n "${TOKEN_SORT_NAME:-}" ]; then
  for _i in "${!SORTS[@]}"; do
    [ "${SORTS[$_i]}" = "$TOKEN_SORT_NAME" ] && { SORT=$_i; break; }
  done
  [ "${SORTS[$SORT]}" = "$TOKEN_SORT_NAME" ] ||     BADARG="$BADARG --sort=$TOKEN_SORT_NAME (try: ${SORTS[*]})"
fi
if [ -n "$BADARG" ]; then
  printf 'token-sessions: unknown option(s):%s\n' "$BADARG" >&2
  printf 'try --help\n' >&2
  exit 2
fi
# A refresh faster than a collect takes is a redraw that never finishes.
case "$EVERY" in *[!0-9]*) EVERY=60 ;; esac
[ "$EVERY" -lt 2 ] && EVERY=2

# Glyphs are built with printf from escapes rather than pasted literally, so the
# script stays pure ASCII on disk and cannot be mangled by an editor or a
# terminal running a non-UTF-8 codepage.
if [ "$ASCII" = 1 ]; then
  G_FULL="#"; G_EMPT="."; G_DOT="*"; G_HERE=">"; G_ARROW="->"; G_SEL="|"
  G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"; G_H="-"; G_V="|"; G_PARK="P"; G_LAST="-"; G_FS="~"
  G_UP="^"; G_DN="v"; G_VF="|"
  G_ACT="!"; G_CUT="v"; G_OK="."
  G_PTL="+"; G_PTR="+"; G_PBL="+"; G_PBR="+"; G_PH="-"; G_PV="|"
  G_PML="+"; G_PMR="+"
  G_DH="."; G_DV=":"
  SPARKS="_ . - = + * ^ #"
elif [ "$THEME" = hud ]; then
  # Heavy frame, hard corners, a filled status lamp. The rounded box and the
  # hollow dot read as a document; this reads as an instrument, which is what
  # the thing actually is - a panel you leave running and glance at.
  #
  # Every glyph here is still exactly one column wide, which is not decoration:
  # pad() counts BYTES, so the layout only survives because a three-byte glyph
  # occupies one cell. Anything double-width would take the columns apart.
  G_FULL="\xe2\x96\x88"; G_EMPT="\xe2\x96\x91"; G_DOT="\xe2\x97\x89"
  G_HERE="\xe2\x96\xb6"; G_ARROW="\xe2\x86\x92"; G_SEL="\xe2\x96\x8c"
  G_TL="\xe2\x94\x8f"; G_TR="\xe2\x94\x93"; G_BL="\xe2\x94\x97"; G_BR="\xe2\x94\x9b"
  G_H="\xe2\x94\x81"; G_V="\xe2\x94\x83"; G_PARK="\xe2\x97\x88"; G_LAST="\xe2\x96\xb7"
  G_FS="\xe2\x9f\xb3"
  G_UP="\xe2\x86\x91"; G_DN="\xe2\x86\x93"
  # The verdict glyphs. One column and three bytes each, like everything else
  # here - a filled triangle for "do something now", a hollow one for "a cut
  # would pay if you want it", a ring for "nothing to decide".
  G_ACT="\xe2\x96\xb2"; G_CUT="\xe2\x96\xbd"; G_OK="\xe2\x97\xa6"
  # The thin frame. Every block on screen sits in one of these; only the title
  # keeps the heavy rule, so the hierarchy is carried by weight rather than by
  # blank space. Light box-drawing, one column and three bytes each.
  G_PTL="\xe2\x94\x8c"; G_PTR="\xe2\x94\x90"; G_PBL="\xe2\x94\x94"
  G_PBR="\xe2\x94\x98"; G_PH="\xe2\x94\x80"; G_PV="\xe2\x94\x82"
  G_PML="\xe2\x94\x9c"; G_PMR="\xe2\x94\xa4"
  G_VF="\xe2\x94\x83"; G_V="\xe2\x94\x82"
  # The dotted frame, one weight below the thin one. The detail region is drawn
  # in it so it reads as secondary to the panel it hangs under - the same
  # grammar, quieter. Quadruple-dash box drawing, still one column and three
  # bytes each.
  G_DH="\xe2\x94\x88"; G_DV="\xe2\x94\x8a"
  SPARKS="\xe2\x96\x81 \xe2\x96\x82 \xe2\x96\x83 \xe2\x96\x84 \xe2\x96\x85 \xe2\x96\x86 \xe2\x96\x87 \xe2\x96\x88"
else
  G_FULL="\xe2\x96\x88"; G_EMPT="\xe2\x96\x91"; G_DOT="\xe2\x97\x8f"
  G_HERE="\xe2\x96\xb6"; G_ARROW="\xe2\x86\x92"; G_SEL="\xe2\x96\x8c"
  G_TL="\xe2\x95\xad"; G_TR="\xe2\x95\xae"; G_BL="\xe2\x95\xb0"; G_BR="\xe2\x95\xaf"
  G_H="\xe2\x94\x80"; G_V="\xe2\x94\x82"; G_PARK="\xe2\x97\x87"; G_LAST="\xe2\x96\xb7"
  G_FS="\xe2\x9f\xb3"
  G_UP="\xe2\x86\x91"; G_DN="\xe2\x86\x93"
  G_ACT="\xe2\x96\xb2"; G_CUT="\xe2\x96\xbd"; G_OK="\xe2\x97\xa6"
  G_PTL="\xe2\x95\xad"; G_PTR="\xe2\x95\xae"; G_PBL="\xe2\x95\xb0"
  G_PBR="\xe2\x95\xaf"; G_PH="\xe2\x94\x80"; G_PV="\xe2\x94\x82"
  G_PML="\xe2\x94\x9c"; G_PMR="\xe2\x94\xa4"
  G_DH="\xe2\x94\x88"; G_DV="\xe2\x94\x8a"
  SPARKS="\xe2\x96\x81 \xe2\x96\x82 \xe2\x96\x83 \xe2\x96\x84 \xe2\x96\x85 \xe2\x96\x86 \xe2\x96\x87 \xe2\x96\x88"
fi
# '%b' and not a bare format string: in ASCII mode G_ARROW is "->", which printf
# would read as an option and refuse.
G_FULL=$(printf '%b' "$G_FULL"); G_EMPT=$(printf '%b' "$G_EMPT"); G_DOT=$(printf '%b' "$G_DOT")
G_HERE=$(printf '%b' "$G_HERE"); G_ARROW=$(printf '%b' "$G_ARROW"); G_SEL=$(printf '%b' "$G_SEL")
G_TL=$(printf '%b' "$G_TL"); G_TR=$(printf '%b' "$G_TR")
G_BL=$(printf '%b' "$G_BL"); G_BR=$(printf '%b' "$G_BR")
G_H=$(printf '%b' "$G_H"); G_V=$(printf '%b' "$G_V"); SPARKS=$(printf '%b' "$SPARKS")
G_PARK=$(printf '%b' "$G_PARK"); G_LAST=$(printf '%b' "$G_LAST"); G_FS=$(printf '%b' "$G_FS")
# The classic frame and the inline separator are the same glyph; only the
# hud splits them, so this defaults rather than being set in three places.
: "${G_VF:=$G_V}"; G_VF=$(printf '%b' "$G_VF")
G_UP=$(printf '%b' "$G_UP"); G_DN=$(printf '%b' "$G_DN")
G_ACT=$(printf '%b' "$G_ACT"); G_CUT=$(printf '%b' "$G_CUT"); G_OK=$(printf '%b' "$G_OK")
G_DH=$(printf '%b' "$G_DH"); G_DV=$(printf '%b' "$G_DV")
G_PTL=$(printf '%b' "$G_PTL"); G_PTR=$(printf '%b' "$G_PTR")
G_PBL=$(printf '%b' "$G_PBL"); G_PBR=$(printf '%b' "$G_PBR")
G_PH=$(printf '%b' "$G_PH"); G_PV=$(printf '%b' "$G_PV")
G_PML=$(printf '%b' "$G_PML"); G_PMR=$(printf '%b' "$G_PMR")

if [ "$COLOR" = 1 ] && [ "$THEME" = hud ]; then
  # Muted instrument, not neon. The palette used to be full-saturation phosphor
  # (48/227/208/197/45/51), which on a pane you leave running all day is six
  # colours all shouting at once - and when everything is loud, the one row that
  # actually wants attention has nothing left to say it with. These are the same
  # six hues at reduced chroma, so the dim/bold axis does the work of
  # separating background from foreground and colour is left to carry MEANING
  # alone. The meanings are untouched: green nothing to do, red money on the
  # floor, and teal for the live states (selection, a turn in flight).
  #
  # Chroma is not the same lever as contrast, and the first cut of this palette
  # confused them - it dropped saturation AND luminance together, which is how
  # 167/67/242 ended up at 3.79/3.71/2.67 against a One Dark background: under
  # the 4.5:1 WCAG AA floor for body text, and well under it again once C_DIM
  # halves them. Contrast is a LUMINANCE ratio, so the fix is to lift each hue
  # up the 6x6x6 cube without re-saturating it - 108->151 and 73->116 are in
  # fact LESS saturated than what they replace and still read at half again the
  # contrast. Measured against #0c0c0c (Windows Terminal), #1e1e1e (VS Code)
  # and #282c34 (One Dark); the figure below is the worst of the three:
  #   GRN 151  8.77   YEL 186  9.31   ORG 216  7.82   RED 174  5.14
  #   BLU 110  6.10   CYN 116  8.49   GRY 246  4.61
  # All seven clear AA on the darkest of those; all but the two meant to recede
  # clear AAA at 7:1 - RED stays an alarm by hue rather than by brightness, and
  # GRY is the label colour, which has to lose to the content beside it. Hue
  # separation was held as well: YEL sits at 60 degrees, ORG at 20, RED at 0,
  # so the three warm channels stay tellable apart at a glance, which is what
  # chasing brightness alone would have destroyed.
  E=$(printf '\033')
  C_R="$E[0m"; C_DIM="$E[2m"; C_B="$E[1m"
  C_GRN="$E[38;5;151m"; C_YEL="$E[38;5;186m"; C_ORG="$E[38;5;216m"
  C_RED="$E[38;5;174m"; C_BLU="$E[38;5;110m"; C_GRY="$E[38;5;246m"
  C_CYN="$E[38;5;116m"
elif [ "$COLOR" = 1 ]; then
  # The bright theme was already close: only its two dimmest entries sat under
  # AA on a One Dark background (RED 203 at 4.70, GRY 244 at 3.54). Those two
  # move and nothing else does - the rest measure between 6.1 and 10.1, and
  # lifting them too would only flatten the difference from hud.
  E=$(printf '\033')
  C_R="$E[0m"; C_DIM="$E[2m"; C_B="$E[1m"
  C_GRN="$E[38;5;78m"; C_YEL="$E[38;5;221m"; C_ORG="$E[38;5;215m"
  C_RED="$E[38;5;210m"; C_BLU="$E[38;5;110m"; C_GRY="$E[38;5;246m"
  C_CYN="$E[38;5;80m"
else
  C_R=""; C_DIM=""; C_B=""; C_GRN=""; C_YEL=""; C_ORG=""; C_RED=""; C_BLU=""
  C_GRY=""; C_CYN=""
fi

# One flag for the two awk programs, rather than each re-deriving the theme.
if [ "$THEME" = hud ]; then HUD=1; else HUD=0; fi

# First (mode=first) or last (mode=last) human turn of a transcript, decoded out
# of the JSON and flattened to one ASCII line. Only lines carrying
# origin.kind=human count: a tool_result and a <system-reminder> are both "user"
# messages and neither is something the user typed.
# mode=probe additionally reports how long ago the transcript last had anything
# WRITTEN to it, which is not the same question as its mtime - see collect().
prompt_of() {
  awk -v mode="$2" '
    # An ISO timestamp out of a record, read as UTC. Both sides of the
    # subtraction go through mktime with the same (local) rule, so whatever
    # that rule gets wrong cancels - which is why this returns an age and not
    # an epoch. Converting to a real epoch would need the zone offset, and
    # getting that wrong by an hour is exactly the error the cache clock cannot
    # absorb.
    function utcep(s,   d) {
      if (!match(s, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/))
        return 0
      d = substr(s, RSTART, 19); gsub(/[-T:]/, " ", d)
      return mktime(d) }
    function dec(s,   i, ch, nx, out) {
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") { nx = substr(s, i + 1, 1); i++
          if (nx == "\"") out = out "\""
          else if (nx == "\\") out = out "\\"
          else if (nx == "u") { i += 4; out = out "?" }
          else out = out " "
          continue }
        if (ch == "\"") break
        out = out ch
        if (length(out) > 300) break }
      return out }
    BEGIN { NOWU = mktime(strftime("%Y %m %d %H %M %S", systime(), 1)) }
    mode == "probe" && match($0, /"timestamp":"[0-9][0-9][0-9][0-9]-/) {
      e = utcep(substr($0, RSTART + 13, 19)); if (e > lastts) lastts = e }
    # The working directory, which for a session with no pid file left on disk
    # is the only place its project name can come from. Every record carries it,
    # so the first one seen settles it and the match is skipped thereafter.
    mode == "probe" && cwd == "" && match($0, /"cwd":"[^"]*"/) {
      cwd = substr($0, RSTART + 7, RLENGTH - 8); gsub(/\|/, "/", cwd) }
    /"origin":\{"kind":"human"\}/ {
      if (!match($0, /"content":\[\{"type":"text","text":"/)) next
      t = dec(substr($0, RSTART + RLENGTH))
      gsub(/[^ -~]/, "", t); gsub(/\|/, "/", t)
      gsub(/[ \t]+/, " ", t); sub(/^ +/, "", t); sub(/ +$/, "", t)
      if (t == "" || t ~ /^</ || t ~ /^\[Request interrupted/) next
      if (mode == "first") { print t; exit }
      l = t }
    END {
      if (mode == "probe") { printf "%d|%s|%s\n", (lastts > 0 ? NOWU - lastts : -1), cwd, l; exit }
      if (mode != "first" && l != "") print l }' "$1"
}

# Every /park checkpoint on disk, newest first: mtime, the session= stamp that
# says which window wrote it, and the first lines of its Task in flight. Three
# spawns for the whole directory - the awk opens each file itself rather than
# paying a grep per file, and stops after the header, since everything wanted
# is in the first few dozen lines.
declare -A CK CS CKT
CKN=()
scan_checkpoints() {
  local cm cf sid task
  CK=(); CS=(); CKT=(); CKN=()
  while IFS='|' read -r cm cf sid task; do
    [ -n "$cf" ] || continue
    CK[$cf]=$cm; CS[$cf]=$sid; CKT[$cf]=$task; CKN+=("$cf")
  done < <(stat -c '%Y|%n' "$CL"/checkpoints/*.md 2>/dev/null | sort -t'|' -k1,1nr |
    awk -F'|' '{
      path = $2; name = path; sub(/.*[\/\\]/, "", name)
      sid = ""; task = ""; intask = 0; ln = 0
      while ((getline line < path) > 0) {
        ln++
        if (ln <= 4 && match(line, /session=[0-9a-f]+/))
          sid = substr(line, RSTART + 8, RLENGTH - 8)
        if (line ~ /^#+ +Task in flight/) { intask = 1; continue }
        if (intask && line ~ /^#+ /) break
        if (intask && line ~ /[^ \t]/) {
          gsub(/[|\r]/, " ", line)
          task = task (task == "" ? "" : " ") line
          if (length(task) > 200) break }
        if (ln > 80) break }
      close(path)
      gsub(/^ +| +$/, "", task)
      print $1 "|" name "|" sid "|" task }')
}

# A checkpoint's topic is whatever the filename carries between the project and
# the extension - "MyGame.shader-rework.md" is the shader-rework
# topic. The old one-per-project "MyGame.md" has none, so it reads
# as the general one. Sets TOPIC rather than echoing: a command substitution
# here is a fork, and this is called once per checkpoint per session.
topic_of() {
  local t=${1%.md}
  t=${t#"$2"}; t=${t#.}
  TOPIC=${t:-general}
}

# Minutes -> "45m" / "6h" / "3d". Same reason for the global.
agestr() {
  if   [ "$1" -lt 60 ];   then AGE="${1}m"
  elif [ "$1" -lt 2880 ]; then AGE="$(($1 / 60))h"
  else                         AGE="$(($1 / 1440))d"; fi
}

# Everything here is batched, because a process spawn under Git Bash costs
# ~55ms and this used to launch about 130 of them - a 7.5s freeze on every
# refresh, during which the watch loop ate no input at all. That was the whole
# of the "controls jitter and take too long" problem. It is now six fixed
# spawns plus three per live session.
collect() {
  local now pidset psout f b k v rest cf d best ckmt age nother nmeta
  local pid sid alive name cwd proj short tf mtime idle left act probe page touched
  local ctx trend cyc otot olast rlast stop title lastp run parked ckage ckname
  local cktopic ckothers ckdist cached pcwd nclosed nhidden
  local -a SHOW CAND
  now=${EPOCHSECONDS:-$(date +%s)}

  # Every Windows pid on the machine as one padded string, for index() tests.
  # ps -W beats tasklist by 3x here and still sees native processes; column 1
  # is the msys pid and column 4 the Windows one, and a session file can carry
  # either, so both go in.
  #
  # A pid on its own does NOT identify a session. Windows recycles pids freely
  # and sessions/<pid>.json outlives the process that wrote it, so opening a
  # new IDE project - which spawns dozens of processes at once - is enough to
  # hand a fresh, unrelated process the pid of a Claude session that closed days
  # ago. That session then appears here as live, with a cache clock counting
  # down on a window nobody is holding. So the pid must ALSO belong to something
  # that looks like Claude.
  #
  # Matched against the whole line, not $8: the command is everything from
  # field 8 on and these paths contain spaces. If the filter leaves nothing at
  # all it is the filter that is wrong, not the machine that is idle - a
  # renamed binary, some other launcher - so it falls back to the unfiltered
  # set rather than reporting no sessions at all.
  #
  # COLUMNS=1000 is load-bearing, not tidiness. ps truncates every line to the
  # terminal width, and the command here is a ~105-character path under
  # .vscode/extensions, so in an 80- or 110-column window the word "claude" is
  # cut off the end of the line and the filter above throws away a live session.
  # The fallback does not save it either: the set is non-empty, just short. This
  # cost an afternoon once - a tool that reported "no sessions found" while four
  # were running.
  psout=$(COLUMNS=1000 ps -W 2>/dev/null)
  pidset=" $(printf '%s\n' "$psout" |
    awk 'NR > 1 && tolower($0) ~ /claude|node[.]exe/ { print $1; print $4 }' | tr '\n' ' ') "
  [ "${#pidset}" -gt 2 ] || pidset=" $(printf '%s\n' "$psout" |
    awk 'NR > 1 { print $1; print $4 }' | tr '\n' ' ') "

  local -A TF TI HS MT SM SA LA

  # sid -> transcript path AND mtime, from one stat over the whole glob. This
  # used to be a shell loop here plus a stat per session further down; batching
  # it is what makes enumerating a hundred closed sessions affordable.
  while IFS='|' read -r v f; do
    [ -n "$f" ] || continue
    b=${f##*/}; b=${b%.jsonl}
    TF[$b]="$f"; MT[$b]="$v"
  done < <(stat -c '%Y|%n' "$CL"/projects/*/*.jsonl 2>/dev/null)

  # sid -> cached title, read whole rather than grepped once per session.
  if [ -f "$TITLES" ]; then
    while IFS=$'\t' read -r k v; do [ -n "$k" ] && TI[$k]="$v"; done < "$TITLES"
  fi

  # sid -> "mtime<TAB>last-activity<TAB>cwd", for CLOSED sessions only. A closed
  # session has to be probed the same way a live one is (see below), and that
  # probe is the dearest read left in here - so it is done once per session and
  # remembered. Keyed by mtime so a transcript that grows is re-probed and one
  # that has not moved never is.
  if [ -f "$META" ]; then
    nmeta=0
    while IFS=$'\t' read -r k v rest; do
      [ -n "$k" ] || continue
      LA[$k]="$v	$rest"; nmeta=$((nmeta + 1))
    done < "$META"
    # Appended, so a re-probed session leaves its old row behind and the last
    # one read wins. Compacted only once it has gone mostly stale: a cache that
    # only ever grows is a slow leak, and rewriting it every collect is worse
    # than the leak.
    if [ "$nmeta" -gt 200 ] && [ "$nmeta" -gt $(( ${#LA[@]} * 3 )) ]; then
      : > "$META"
      for k in "${!LA[@]}"; do printf '%s\t%s\n' "$k" "${LA[$k]}"; done >> "$META"
    fi
  fi

  scan_checkpoints

  # short sid -> ctx|trend|cycles|output|lastout|lastrecache|laststop|recache|
  # growth|breaches|gaprewrites, in a single pass over the history instead of
  # three awks per session. laststop is the epoch of the last Stop hook, which
  # is what makes "a turn is running" decidable: the hook fires when a cycle
  # ENDS, so a transcript written after it means the next cycle has begun.
  while IFS='|' read -r k rest; do
    [ -n "$k" ] && HS[$k]="$rest"
  done < <(awk -F, 'NR > 1 && $2 != "" {
        # Growth is the context this cycle ADDED - the half the prompt chose.
        # Churn is the rest of the re-cache: the window being rewritten, which
        # nothing but a shorter session avoids. Cycle 1 has no predecessor, so
        # it scores zero growth rather than blaming a prompt for the cold floor.
        g = (($2 in pv) ? $6 - pv[$2] : 0); if (g < 0) g = 0
        ch = $5 - g; if (ch < 0) ch = 0
        pv[$2] = $6
        c[$2] = $6 + 0; n[$2]++; o[$2] += $4; lo[$2] = $4; lr[$2] = $5
        rt[$2] += $5; gt[$2] += g
        if ($7 != "-" && $7 != "") fb[$2]++
        # A churn spike this size is a cache that lapsed and was rewritten -
        # the one line in the table a /park would have removed outright.
        #
        # Cycle 1 is excluded, and that exclusion is the whole point: on the
        # opening cycle growth is defined as zero, so the entire cold load
        # lands in churn and every session would score a rewrite it never had.
        if ($3 + 0 > 1 && ch > 60000) gp[$2]++
        ts[$2] = $1
        # The trend carries growth AND that cycle output, so the sparkline can
        # draw one and colour by the other. Context itself only ever rises,
        # which is why drawing it made every session look like the same ramp.
        td[$2] = td[$2] " " g ":" $4 }
      END { for (k in c) {
          # 12, matching the widest the sparkline column ever gets. It was 8,
          # which silently capped the trend at eight cycles - so widening the
          # column would have bought four blank cells rather than four more
          # cycles of history.
          m = split(td[k], a, " "); s = (m > 12 ? m - 11 : 1); t = ""
          for (i = s; i <= m; i++) t = t (t == "" ? "" : " ") a[i]
          # "2026-08-24 15:28" -> epoch. Minute resolution, so the reader has to
          # allow a minute of slack before calling a session busy.
          st = ts[k]; gsub(/[-:]/, " ", st); e = mktime(st " 00"); if (e < 0) e = 0
          printf "%s|%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", k, c[k], t, n[k], o[k], \
            lo[k], lr[k], e, rt[k], gt[k], fb[k] + 0, gp[k] + 0 } }' \
      <(hist_rows) 2>/dev/null)

  # Session metadata from every pid file, in one awk. Liveness is decided here
  # rather than in the loop, and a live record always beats a stale one for the
  # same sid - two pids can name one session.
  while IFS='|' read -r pid sid alive name cwd; do
    [ -n "$sid" ] || continue
    # A live record beats a dead one for the same sid whichever order the files
    # arrive in. Backwards, this silently marks a RUNNING session closed - it
    # takes only one stale pid file still naming it.
    [ -n "${SA[$sid]:-}" ] && [ "${SA[$sid]}" -ge "$alive" ] && continue
    SA[$sid]=$alive; SM[$sid]="$pid|$name|$cwd"
  done < <(awk -v pidset="$pidset" '
      function jv(s, k,   r) {
        if (!match(s, "\"" k "\":\"[^\"]*\"")) return ""
        r = substr(s, RSTART, RLENGTH)
        sub("^\"" k "\":\"", "", r); sub("\"$", "", r); return r }
      { p = FILENAME; sub(/.*[\/\\]/, "", p); sub(/\.json$/, "", p)
        s = jv($0, "sessionId"); if (s == "") next
        printf "%s|%s|%d|%s|%s\n", p, s, (index(pidset, " " p " ") ? 1 : 0), \
          jv($0, "name"), jv($0, "cwd") }' \
      "$CL"/sessions/*.json 2>/dev/null)

  # Which sessions there ARE.
  #
  # sessions/<pid>.json used to be the only source here, and it is a lossy
  # index: it is keyed by PID, so a recycled pid overwrites the record of the
  # session that held it before, and a cleaned-up file loses one outright.
  # Measured when this was written - 106 transcripts on disk, 16 sids still
  # named by a pid file - so --all, which every reader takes to mean "every
  # session", was showing 15% of them.
  #
  # The TRANSCRIPTS are the register. Pid files now only decide liveness and
  # supply the CLI's own name; everything else is enumerated from projects/.
  # Closed sessions are capped, because a month of them is not a screenful:
  # the most recently active CLOSED_MAX are shown and the rest are counted.
  SHOW=()
  for sid in "${!TF[@]}"; do
    [ "${SA[$sid]:-0}" = 1 ] && SHOW+=("$sid")
  done
  nclosed=0; nhidden=0
  if [ "$SHOW_ALL" = 1 ]; then
    CAND=()
    for sid in "${!TF[@]}"; do
      [ "${SA[$sid]:-0}" = 1 ] && continue
      # Rank on the cheap answer - the last Stop-hook row, already collected and
      # free - and let only the survivors pay for a probe. Ranking can be no
      # coarser than the cut it feeds: mtime is the fallback, and the probe
      # below only ever moves a session DOWN the order, never up past the cut.
      rest="${HS[${sid:0:8}]:-}"; act=0
      if [ -n "$rest" ]; then act=${rest#*|*|*|*|*|*|}; act=${act%%|*}; fi
      case "$act" in ''|*[!0-9]*) act=0 ;; esac
      [ "$act" -gt 0 ] || act=${MT[$sid]:-0}
      CAND+=("$act|$sid")
      nclosed=$((nclosed + 1))
    done
    if [ "$nclosed" -gt 0 ]; then
      while IFS='|' read -r v k; do
        [ -n "$k" ] && SHOW+=("$k")
      done < <(printf '%s\n' "${CAND[@]}" | sort -t'|' -k1,1nr | head -n "$CLOSED_MAX")
    fi
    nhidden=$(( nclosed - CLOSED_MAX )); [ "$nhidden" -lt 0 ] && nhidden=0
  fi
  # A count, not a row: the renderer prints it as a footer under the table so
  # that "12 closed" never reads as "12 closed sessions exist".
  [ "$nhidden" -gt 0 ] && printf '#|hidden|%s|%s\n' "$nhidden" "$nclosed"

  for sid in ${SHOW[@]+"${SHOW[@]}"}; do
    tf="${TF[$sid]:-}"; [ -n "$tf" ] || continue
    mtime="${MT[$sid]:-0}"; [ "$mtime" -gt 0 ] || continue

    short=${sid:0:8}
    alive="${SA[$sid]:-0}"
    rest="${SM[$sid]:-}"
    if [ -n "$rest" ]; then
      pid=${rest%%|*}; rest=${rest#*|}; name=${rest%%|*}; cwd=${rest#*|}
    else
      pid="-"; name="-"; cwd=""
    fi
    [ -n "$name" ] || name="-"
    rest="${HS[$short]:-0||0|0|0|0|0|0|0|0|0}"
    IFS='|' read -r ctx trend cyc otot olast rlast stop rtot gtot brch gaps <<< "$rest"

    # When this session last actually DID something, and what was last typed
    # into it - one pass over the tail for both.
    #
    # The file's mtime is not the answer to the first question, and used to be
    # taken as if it were. Resuming a session touches the transcript without
    # adding a record, so a window the IDE reopened at startup looked like it
    # had been active seconds ago and reported a full hour of cache life it did
    # not have. Measured here when this was written: two transcripts sat 319 and
    # 877 minutes newer than their own last record. The cache clock runs from
    # the last request, and the last record is the closest thing on disk to it;
    # the Stop hook's own timestamp backs it up at minute resolution.
    #
    # Closed sessions are prone to exactly the same error, and used to be left
    # with it on the grounds that their cache is gone either way - but the
    # ORDER of the closed band is read as "what was I last doing", and a touched
    # mtime bumps a session nobody has spoken to for days straight to the top of
    # it. They get the same probe, once, cached by mtime; and where the Stop
    # hook has seen the session at all, its last row settles the question for
    # free and no probe is needed.
    act=$mtime; lastp=""; pcwd=""; page=-1
    if [ "$alive" = 1 ]; then
      probe=$(tail -c 400000 "$tf" 2>/dev/null | prompt_of /dev/stdin probe)
      page=${probe%%|*}; probe=${probe#*|}; pcwd=${probe%%|*}; lastp=${probe#*|}
      case "$page" in ''|*[!0-9-]*) page=-1 ;; esac
      [ "$page" -ge 0 ] && act=$(( now - page ))
      [ "${stop:-0}" -gt "$act" ] && act=$stop
    else
      cached="${LA[$sid]:-}"
      if [ "${cached%%	*}" = "$mtime" ]; then
        cached=${cached#*	}; act=${cached%%	*}; pcwd=${cached#*	}; page=0
      elif [ "${stop:-0}" -le 0 ] || [ -z "$cwd" ]; then
        probe=$(tail -c 400000 "$tf" 2>/dev/null | prompt_of /dev/stdin probe)
        page=${probe%%|*}; probe=${probe#*|}; pcwd=${probe%%|*}
        case "$page" in ''|*[!0-9-]*) page=-1 ;; esac
        [ "$page" -ge 0 ] && act=$(( now - page ))
        printf '%s\t%s\t%s\t%s\n' "$sid" "$mtime" "$act" "$pcwd" >> "$META"
      fi
      # The probe is the finer of the two - a record timestamp against the
      # minute the hook fired - so it wins where there is one, and the hook row
      # is what stands in for it where there is not.
      if [ "$page" -lt 0 ]; then
        if [ "${stop:-0}" -gt 0 ]; then act=$stop; else act=$mtime; fi
      fi
    fi
    [ -n "$cwd" ] || cwd="$pcwd"
    proj=${cwd//\\//}; proj=${proj%/}; proj=${proj##*/}; [ -n "$proj" ] || proj="-"
    idle=$(( (now - act) / 60 )); [ "$idle" -lt 0 ] && idle=0
    left=$(( TTL - idle ))
    # A wide gap between the mtime and the last record is the signature of a
    # session reopened and not spoken to. Worth saying out loud in the panel:
    # it is the one state where "live process, dead cache" is correct and still
    # looks like a bug.
    touched=$(( (mtime - act) / 60 )); [ "$touched" -lt 5 ] && touched=0

    # Parked. A project can hold several checkpoints at once, one per topic, so
    # the question is which one belongs to THIS window:
    #   - a session= stamp is definitive, and ages fine - a checkpoint written
    #     a week ago still belongs to the session that wrote it;
    #   - an unstamped file predates the stamp, so it falls back to the old
    #     mtime match: within ten minutes either side of the session's last
    #     activity. A session that parked and then kept working for half an
    #     hour drops out of that window, which is the point - a stale
    #     checkpoint is not a park.
    # Stamped files belonging to someone else are never claimed by mtime, which
    # is what stops two sessions in one project from both showing parked.
    parked=0; ckage=-1; ckname=""; ckmt=0; cktopic=""; ckothers=""; ckdist=-1
    for cf in "${CKN[@]}"; do
      case "$cf" in "$proj".md|"$proj".*.md) ;; *) continue ;; esac
      if [ -n "${CS[$cf]}" ] && [ "${CS[$cf]:0:8}" = "$short" ]; then
        parked=1; ckname="$cf"; ckmt=${CK[$cf]}; break
      fi
    done
    if [ "$parked" = 0 ]; then
      best=-1
      for cf in "${CKN[@]}"; do
        case "$cf" in "$proj".md|"$proj".*.md) ;; *) continue ;; esac
        [ -n "${CS[$cf]}" ] && continue
        d=$(( ${CK[$cf]} - act )); [ "$d" -lt 0 ] && d=$(( -d ))
        if [ "$best" -lt 0 ] || [ "$d" -lt "$best" ]; then
          best=$d; ckname="$cf"; ckmt=${CK[$cf]}
        fi
      done
      if [ "$best" -ge 0 ] && [ "$best" -le 600 ]; then
        parked=1; ckdist=$best
      else ckname=""; fi
    fi
    if [ "$parked" = 1 ]; then
      ckage=$(( (now - ckmt) / 60 ))
      topic_of "$ckname" "$proj"; cktopic=$TOPIC
    fi

    # Everything else parked for this project, newest first. This is what makes
    # several topics usable: the panel can say what ELSE is waiting, so a fresh
    # session knows there is a shader-rework checkpoint to resume as well.
    nother=0
    for cf in "${CKN[@]}"; do
      case "$cf" in "$proj".md|"$proj".*.md) ;; *) continue ;; esac
      [ "$cf" = "$ckname" ] && continue
      topic_of "$cf" "$proj"; agestr $(( (now - ${CK[$cf]}) / 60 ))
      ckothers="${ckothers:+$ckothers, }$TOPIC $AGE"
      nother=$((nother + 1)); [ "$nother" -ge 4 ] && break
    done

    # Running: the transcript has been written since the last Stop hook (+90s
    # of slack for the minute-resolution timestamp) and was touched recently
    # enough that this is a live turn rather than an interrupted one. With no
    # history at all the hook has never fired, so freshness is all there is.
    run=0; age=$(( now - act ))
    if [ "$alive" = 1 ]; then
      if [ "${stop:-0}" -gt 0 ]; then
        [ "$age" -le 600 ] && [ "$act" -gt $(( stop + 90 )) ] && run=1
      else
        [ "$age" -le 120 ] && run=1
      fi
    fi

    title="${TI[$sid]:-}"
    if [ -z "$title" ]; then
      title=$(prompt_of "$tf" first)
      if [ -n "$title" ]; then printf '%s\t%s\n' "$sid" "$title" >> "$TITLES"
      else title="(no prompt yet)"; fi
    fi

    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$short" "$alive" "$idle" "$left" "$ctx" "${name:0:34}" "$trend" \
      "$pid" "$proj" "$title" "$cyc" "$otot" "$olast" "$rlast" "$sid" "$tf" "$lastp" \
      "$run" "$parked" "$ckage" "$ckname" "$cktopic" "$ckothers" "$ckdist" \
      "$rtot" "$gtot" "$brch" "$gaps" "$touched" "$cwd"
  done
}

# One line per session, deduped by sessionId (two pids can share one) and
# ordered warm-soonest first, then COLD by idle, then closed. Ordering lives
# here rather than in the renderer so that a selection index means the same
# row to both this script and awk.
snapshot() {
  collect | awk -F'|' '
    # Counts, not sessions. Sorted to the front so that a reader taking the
    # first N lines of this still gets rows, and skipped by the renderer.
    /^#/ { print "0000000|" $0; next }
    { k = $1
      if (!(k in seen) || $2 > al[k] || ($2 == al[k] && $3 + 0 < id[k])) {
        seen[k] = 1; al[k] = $2 + 0; id[k] = $3 + 0; lf[k] = $4 + 0; line[k] = $0 } }
    END {
      # One checkpoint belongs to one window. A stamped file says which (field
      # 24 is -1 there); an unstamped one was claimed by mtime and several
      # sessions in the same project can be inside that window at once, so the
      # nearest keeps it and the rest go back to unparked. Without this a single
      # /park lights up every session in the project.
      for (k in seen) {
        split(line[k], f, "[|]")
        if (f[19] + 0 == 1 && f[24] + 0 >= 0)
          if (!(f[21] in bestd) || f[24] + 0 < bestd[f[21]]) {
            bestd[f[21]] = f[24] + 0; bestk[f[21]] = k } }
      for (k in seen) {
        # Rebuilt to the field count split() actually returned, not to a
        # literal. It used to stop at 24 and drop everything after it, so a
        # session that lost a checkpoint here silently lost its recache, growth,
        # breach and gap totals too - and with them its grade and its cost.
        # A row rewrite that truncates is the kind of bug that only shows up in
        # a column added months later.
        nf = split(line[k], f, "[|]")
        if (f[19] + 0 == 1 && f[24] + 0 >= 0 && bestk[f[21]] != k) {
          f[19] = 0; f[20] = -1; f[21] = ""; f[22] = ""
          line[k] = f[1]
          for (j = 2; j <= nf; j++) line[k] = line[k] "|" f[j] } }
      for (k in seen) {
            if (al[k] == 0)     o = 3000000 + id[k]
            else if (lf[k] > 0) o = 1000000 + lf[k]
            else                o = 2000000 + id[k]
            printf "%07d|%s\n", o, line[k] } }' \
  | sort -t'|' -k1,1n | cut -d'|' -f2-
}

# Reads two globals the caller maintains rather than deriving them itself: SECS
# (countdown to the next collect) and COLS. The watch loop redraws once a
# second to keep that countdown live, so a frame costs exactly one process and
# reads nothing off disk beyond the snapshot.
render() {
  local snap="$1" sel="$2" cols="$COLS"

  awk -F'|' \
    -v ttl="$TTL" -v ctxmax="$CTXMAX" -v every="$EVERY" -v watch="$WATCH" \
    -v sel="$sel" -v compact="$COMPACT" -v cols="$cols" -v secs="$SECS" \
    -v full="$G_FULL" -v empt="$G_EMPT" -v dot="$G_DOT" -v here="$G_HERE" \
    -v arrow="$G_ARROW" -v selbar="$G_SEL" -v park="$G_PARK" -v last="$G_LAST" \
    -v tl="$G_TL" -v tr="$G_TR" -v bl="$G_BL" -v br="$G_BR" -v hh="$G_H" -v vv="$G_V" \
    -v vf="$G_VF" \
    -v sparks="$SPARKS" -v clock="$(date '+%H:%M:%S')" \
    -v R="$C_R" -v D="$C_DIM" -v B="$C_B" -v GRN="$C_GRN" -v YEL="$C_YEL" \
    -v ORG="$C_ORG" -v RED="$C_RED" -v BLU="$C_BLU" -v GRY="$C_GRY" -v CYN="$C_CYN" \
    -v m_floor="$M_FLOOR" -v m_rd="$M_RD" -v m_cps="$M_CPS" \
    -v p_wpc="$M_WPC" -v p_prod="$M_PROD" -v rpc="$RPC" -v price="$PRICE_IN" \
    -v o_wpc="$O_WPC" -v o_prod="$O_PROD" -v o_ctl="$O_CTL" -v o_n="$O_N" \
    -v v_wpc="$P_WPC" -v v_prod="$P_PROD" -v v_ctl="$P_CTL" -v v_n="$P_N" \
    -v up="$G_UP" -v dn="$G_DN" -v helpv="${HELPV:-0}" \
    -v g_act="$G_ACT" -v g_cut="$G_CUT" -v g_ok="$G_OK" \
    -v m_rem="$M_REM" -v m_heat="$M_HEAT" -v dtl="${DETAIL:-0}" \
    -v tick="${TICK:-0}" \
    -v o_5h="$O_5H" -v o_7d="$O_7D" -v plan5="$PLAN_5H" -v planwk="$PLAN_WK" \
    -v ollv="$SHOW_OLL" -v ckstale="$CK_STALE" \
    -v dth="$G_DH" -v dtv="$G_DV" \
    -v ptl="$G_PTL" -v ptr="$G_PTR" -v pbl="$G_PBL" -v pbr="$G_PBR" \
    -v ph="$G_PH" -v pv="$G_PV" -v pml="$G_PML" -v pmr="$G_PMR" \
    -v rows="${ROWS:-40}" \
    -v obud="$OBUD" -v gbud="$GBUD" -v nicks="$NICKS" -v nvar="$NVAR" \
    -v bell="$BELL" -v bellmin="$BELL_MIN" -v delconf="${DELCONF:-}" \
    -v OLL_PROMPT="$OLL_PROMPT" -v OLL_EVAL="$OLL_EVAL" \
    -v OLL_CALLS="$OLL_CALLS" -v CL_OUT_7D="$CL_OUT_7D" \
    -v hud="$HUD" -v filt="${FILTER:-}" -v srtname="${SORTNAME:-}" \
    -v keytab="$KEYTAB" -v flash="${FLASH:-}" -v ollrows="$OLL_SESSIONS" \
    -v upd="${UPDNEW:-}" -v tsver="$TSVER" '
  function rep(s, n,   i, o) { for (i = 0; i < n; i++) o = o s; return o }
  # Letter-spaced, for the panel titles only. A readout names itself with
  # room around its letters; a paragraph does not. length() stays honest
  # because the spacing is really in the string rather than faked with a
  # terminal attribute - box() measures what it is given.
  function spaced(s,   i, o) {
    for (i = 1; i <= length(s); i++) o = o (i > 1 ? " " : "") substr(s, i, 1)
    return o }
  function hd(s) { return hud ? toupper(s) : s }
  function ttlz(s) { return hud ? spaced(s) : s }
  function bar(frac, w,   n) { n = int(frac * w + 0.5); if (n > w) n = w; if (n < 0) n = 0
                               return rep(full, n) rep(empt, w - n) }
  function pad(s, n,   l) { l = length(s); return (l >= n) ? substr(s, 1, n) : s rep(" ", n - l) }
  function padl(s, n,   l) { l = length(s); return (l >= n) ? substr(s, 1, n) : rep(" ", n - l) s }
  # How many COLUMNS a string occupies once the terminal has eaten the colour
  # escapes. This awk counts bytes, so a three-byte block glyph reads as three
  # and every frame built by hand-counting drifted the moment a glyph moved.
  # Strip the escapes, then strip UTF-8 continuation bytes (0x80-0xBF), and what
  # is left is one byte per character - which is one column, because every glyph
  # in this file is deliberately single-width. This is what let the panels below
  # exist at all: nothing has to declare its own width any more.
  function dwid(s,   t) {
    t = s
    gsub(/\033\[[0-9;]*m/, "", t)
    gsub(/[\200-\277]/, "", t)
    return length(t) }
  # A thin panel, opened with its name written into the top rule. Three calls -
  # pt / pl / pb - and every block on screen is inside one, which is the whole
  # point: an instrument reads as a set of instruments, not as a page of text
  # with a couple of boxes on it.
  # The title is passed in finished - already cased, already coloured - because
  # hd() upper-cases whatever it is handed and an ANSI escape put through
  # toupper() comes out as "\033[2M", which the terminal prints instead of
  # obeying. dwid() then measures what is left after the escapes, so a coloured
  # title still closes its rule in the right column.

  function pt(name,   t) {
    t = (name == "") ? "" : " " name " "
    printf "  %s%s%s%s%s%s%s\n", D, ptl, ph, R, t, D rep(ph, W - 1 - dwid(t)), ptr R }
  function pl(text,   v, q) {
    v = dwid(text); q = W - 2 - v; if (q < 0) q = 0
    printf "  %s%s%s %s%s %s%s%s\n", D, pv, R, text, rep(" ", q), D, pv, R }
  function pb() { printf "  %s%s%s%s%s\n", D, pbl, rep(ph, W), pbr, R }
  # A section boundary INSIDE one panel, rather than the bottom of one panel and
  # the top of the next with a blank line between. Three lines become one, and
  # the pane reads as a single instrument with divisions instead of four boxes
  # stacked up - which is also what it is.
  function pmid(name,   t) {
    t = (name == "") ? "" : " " name " "
    printf "  %s%s%s%s%s%s%s\n", D, pml, ph, R, t, D rep(ph, W - 1 - dwid(t)), pmr R }
  # An empty line INSIDE a panel, so a block can breathe without the frame
  # breaking around it.
  function pgap() { pl("") }
  # Token counts, at a glance rather than to the token. Six characters is all
  # the cost column can spare, and a session that has spent 1.4M does not need
  # the last five digits of it.
  function hum(v) {
    if (v >= 1000000) return sprintf("%.1fM", v / 1000000)
    if (v >= 1000)    return sprintf("%.0fk", v / 1000)
    return sprintf("%d", v) }
  function usd(w) { return w * price / 1000000 }
  function ell(s, n) { return (length(s) > n) ? substr(s, 1, n - 1) "~" : s }
  # One glyph per recent cycle, from "growth:output" pairs.
  #
  # This used to draw the context window itself, min-max normalised per session.
  # Context only ever rises, so that guaranteed a ramp from the lowest glyph to
  # the highest on EVERY session - a 3k session and a 200k one drew the same
  # picture. What it draws now is per-cycle growth on a FIXED scale (the growth
  # budget is the full block), so height means the same thing on every row and
  # the column finally answers the question worth asking: which of my last few
  # prompts were the expensive ones, and why.
  #
  #   height = growth, the new material that cycle pulled in - the half you chose
  #   red    = growth over budget; amber = output over budget; blue = inside both
  function spark(t,   a, n, i, s, ix, g, o, p, c) {
    n = split(t, a, " ")
    # Pad by glyph count, here. Each block char is three bytes and awk may be
    # counting bytes, so padding downstream with substr() slices one in half and
    # the terminal prints a replacement char. A session with fewer than two
    # cycles has no trend to draw and still owes the column its width - that
    # missing pad is what knocked every column right of it out of line.
    if (n < 2) return rep(" ", SPW)
    if (n > SPW) { for (i = 1; i <= SPW; i++) a[i] = a[n - SPW + i]; n = SPW }
    for (i = 1; i <= n; i++) {
      p = index(a[i], ":")
      g = (p ? substr(a[i], 1, p - 1) : a[i]) + 0
      o = (p ? substr(a[i], p + 1) : 0) + 0
      # Fixed ladder, as fractions of the growth budget. Weighted toward the
      # low end because that is where most cycles live - a median cycle should
      # land mid-column, not pinned at the floor.
      ix = (g >= gbud)        ? 8 : \
           (g >= gbud * 0.80) ? 7 : \
           (g >= gbud * 0.60) ? 6 : \
           (g >= gbud * 0.40) ? 5 : \
           (g >= gbud * 0.24) ? 4 : \
           (g >= gbud * 0.12) ? 3 : \
           (g >= gbud * 0.04) ? 2 : 1
      # Growth outranks output: it is charged at the write rate and re-charged
      # on every later miss, so an over-budget read is the dearer of the two.
      c = (g >= gbud) ? RED : ((o > obud) ? YEL : BLU)
      s = s c SP[ix] }
    return s R rep(" ", SPW - n) }
  # A short nickname for a session, built from the opening words of its first
  # prompt. The CLI only ever stores a derived name (mygame-bd),
  # which says nothing about the work, so this is what actually tells two
  # sessions apart at a glance. Stopwords go first, then the first few words
  # that survive, capped so the column never has to truncate mid-word.
  # cap comes from the column, so a word is dropped whole rather than sliced -
  # a nickname cut mid-word is worse than a shorter one.
  function nick(t, cap,   a, i, n, w, out) {
    if (t == "" || substr(t, 1, 1) == "(") return "new-session"
    t = tolower(t); gsub(/[^a-z0-9 ]/, " ", t)
    n = split(t, a, " ")
    for (i = 1; i <= n; i++) {
      w = a[i]
      if (length(w) < 3 || index(STOP, " " w " ")) continue
      if (out != "" && length(out) + 1 + length(w) > cap) continue
      out = (out == "") ? w : out "-" w
      if (length(out) >= cap - 2) break }
    return (out == "") ? substr("session", 1, cap) : out }
  # A re-rolled nickname. Variant 0 is the default above - the opening words of
  # the first prompt - and every variant after it walks a window along the pool
  # of words the session actually used, first prompt then latest, so a re-roll
  # still says something about the work instead of being noise.
  #
  # Deterministic on purpose. token-nicks.tsv stores the INDEX, not the string,
  # so a re-rolled name follows the transcript as the session keeps talking and
  # cannot go stale against it - and nothing here ever writes the name the CLI
  # keeps, which stays in its own column two along.
  function nickv(t, l, cap, v,   pool, np, a, i, j, w, out, seen, P) {
    if (v <= 0) return nick(t, cap)
    pool = tolower(t " " l); gsub(/[^a-z0-9 ]/, " ", pool)
    np = 0; j = split(pool, a, " ")
    for (i = 1; i <= j; i++) {
      w = a[i]
      if (length(w) < 3 || index(STOP, " " w " ") || (w in seen)) continue
      seen[w] = 1; P[++np] = w }
    if (np == 0) return nick(t, cap)
    for (i = 0; i < np; i++) {
      w = P[(v * 2 + i) % np + 1]
      if (out != "" && length(out) + 1 + length(w) > cap) break
      out = (out == "") ? w : out "-" w
      if (length(out) >= cap - 2) break }
    return (out == "") ? nick(t, cap) : out }
  function wrap(s, w, ind,   out, line, i, a, n) {
    n = split(s, a, " ")
    for (i = 1; i <= n; i++) {
      if (line == "") line = a[i]
      else if (length(line) + 1 + length(a[i]) <= w) line = line " " a[i]
      else { out = out ind line "\n"; line = a[i] } }
    return (line == "") ? out : out ind line "\n" }
  # A boxed line cannot measure its own text - colour escapes carry no width -
  # so the caller passes the visible length and the right-hand pad follows from
  # it. Interior is always: space + text + pad + space = W.
  # The heavy outer frame, for the title only. It no longer asks the caller how
  # wide its text is - dwid does that - so every call site that used to carry a
  # parallel, colour-free sprintf of the same line just to count it is gone.
  function box(text,   s, q) {
    q = W - 2 - dwid(text); if (q < 0) q = 0
    s = sprintf("  %s%s%s%s%s\n", D, tl, rep(hh, W), tr, R)
    s = s sprintf("  %s%s%s %s%s %s%s%s\n", D, vf, R, text, rep(" ", q), D, vf, R)
    return s sprintf("  %s%s%s%s%s\n", D, bl, rep(hh, W), br, R) }
  # A labelled block: label in its own 9-wide column, body wrapped under it.
  # Labels here are ASCII on purpose - pad() measures bytes.
  function field(lab, txt, w,   s) {
    s = wrap(txt, w, "    " rep(" ", 9))
    return "    " GRY pad(lab, 9) R substr(s, 14) }
  # One piece of advice, arrow hung in the margin, continuations aligned under
  # the text. The arrow is a three-byte glyph, so its column is spliced in by
  # position rather than padded by length.
  function advice(col, txt, w,   s) {
    s = wrap(txt, w, rep(" ", 6))
    return "    " col arrow R " " substr(s, 7) }

  BEGIN {
    split(sparks, SP, " ")
    STOP = " the and are was were being does did done get got has had have this" \
           " that these those you your our their its lets let not now new old" \
           " for from with into over under about again still just very much more" \
           " most some any all what which who how why when where want need please" \
           " try trying take taken use used using make made can could would should" \
           " will shall may might must after before right only even also here there" \
           " out off back one two but then than they them been but its ive dont" \
           " cant wont didnt doesnt isnt arent were said say says like going gonna" \
           " alright ahead sure okay yeah thanks hey hmm well actually maybe bit" \
           " perhaps really quite lot bunch thing things stuff kind sort way ways" \
           " far yet too own else etc bit lets else since while during between "
    # Which re-roll each session is showing. Read here rather than passed in, so
    # pressing n costs one small write and the next redraw - a second away -
    # picks it up without a collect.
    while ((getline nline < nicks) > 0) {
      np = index(nline, "\t"); if (!np) continue
      nsid = substr(nline, 1, np - 1); nrest = substr(nline, np + 1)
      # Third field, when present, is a name typed with /n. It wins over
      # the derived one outright - the point of typing one is that the
      # words the session used are not what you want to call it.
      nq = index(nrest, "\t")
      if (nq) { NV[nsid] = substr(nrest, 1, nq - 1) + 0
                NC[nsid] = substr(nrest, nq + 1) }
      else      NV[nsid] = nrest + 0 }
    close(nicks)
    if (cols + 0 < 76) cols = 76
    if (cols + 0 > 160) cols = 160
    # 10, not 6: two of margin either side as before, plus the four the panel
    # frame now takes (a border and a space at each end).
    avail = cols - 10
    # The cache column is now the number and nothing else. It used to draw a
    # nine-wide bar alongside "60m", which is two renderings of one scalar
    # taking up the width of a real column - and the bar was the less precise
    # of the two, since what you act on is the minutes. Dropping it hands ~10
    # columns to the two bars that genuinely carry more than one number: the
    # cost split (three shares) and the growth trend (one glyph per cycle).
    if      (avail >= 96) { CBW = 13; SPW = 12 }
    else if (avail >= 82) { CBW = 11; SPW = 10 }
    else if (avail >= 72) { CBW = 9;  SPW = 9 }
    else                  { CBW = 8;  SPW = 7 }
    # Heat is the newest column and the first to go, because it is the only one
    # here that is also stated in words on the line underneath every row.
    HW = (avail >= 88) ? 6 : 0
    # Three letters and a gutter, and only where there is room that the name
    # column was not going to use anyway. On a narrow terminal the grades stay
    # in the detail panel rather than squeezing every other column - a summary
    # is the first thing that should give way, not the thing being summarised.
    GW = (avail >= 90) ? 6 : 0        # three letters, and room for the header
    # The cost column gives way in two steps rather than one: the split bar
    # first, then the figure. The figure is the part that survives, because
    # "1.4M" is the whole point and the bar is the gloss on it.
    CBAR = (avail >= 110) ? 12 : (avail >= 98) ? 9 : (avail >= 86) ? 6 : 0
    COW  = (avail >= 80) ? (CBAR ? CBAR + 8 : 7) : 0
    # 8 = the run mark, the verdict glyph, the park mark and the fail-safe mark,
    # 9 = "%6.1fk" plus its gutter,
    # 5 = the cache label ("COLD" is the longest one now that the bar is gone).
    # Every column width is derived here and the header is drawn from the same
    # numbers, so the two cannot drift apart the way hand-counted %-24s did.
    # Counted off the row printf itself rather than guessed at: 2 gutter, 1 run
    # mark, 1 space, 4 park/fail-safe, -3+1+2+1 for the name suffix, 1 after the
    # context bar, 7 for "%6.1fk", 2, 1 before the cache label, 5 for the label.
    # It was hand-maintained and had drifted by 2 for as long as the lamp column
    # existed, which is why every row punched through the right-hand border the
    # moment there was a border to punch through.
    FIXED = 25 + GW + CBW + HW + COW + SPW
    NAMEW = avail - FIXED - 2
    if (NAMEW > 30) NAMEW = 30           # past this the column is just a gap
    if (NAMEW < 14) NAMEW = 14
    # The frame hugs the table rather than the terminal, so a wide window gets
    # margin instead of a stretched, half-empty box.
    # The panel is exactly the row plus the two columns pl() spends on the space
    # either side of it, so a full-width row can never overrun its own frame.
    W = FIXED + NAMEW + 2
    if (W > avail) W = avail
    NICKW = NAMEW - 3                    # the column, less the derived suffix
    if (NICKW > 20) NICKW = 20
    # Measured constants, in thousands. These arrive from the history when there
    # is enough of it (see measure_floor above); the literals are only the
    # fallback for a machine with no token-history.csv yet. Hardcoding them was
    # a slow leak: the numbers in CLAUDE.md were measured once and every band
    # below is derived from them, so they went stale together and silently.
    FLOOR = (m_floor > 0 ? m_floor : 63)
    RD_NO = (m_rd > 0 ? m_rd : 34)
    RD_PARK = 5; RPC = (rpc + 0 > 0) ? rpc + 0 : 2.3
    CPS = (m_cps > 0 ? m_cps : 6.3)
    RESTART_NO = (FLOOR + RD_NO) * 2; RESTART_PARK = (FLOOR + RD_PARK) * 2
    # How many cycles this window still has to serve. It used to be CPS - the
    # median cycles PER SESSION - which quietly assumed a window you are part
    # way through has a whole session still ahead of it. Measured properly (one
    # observation per position, not per session) it is 4, against a CPS of 7.3,
    # and the cut bars move up ~80k as a result: the tool was calling for a
    # restart well before the arithmetic justified one.
    REM = (m_rem + 0 > 0.5) ? m_rem + 0 : 4
    # The overheat bar, measured rather than chosen: the window size at which
    # the rent a cycle pays merely to HAVE this context overtakes the work that
    # cycle produced. It is not a restart calculation and does not duplicate the
    # cut bars - those ask whether paying the floor again is cheaper, this asks
    # whether the window is still earning its keep. On this history it lands
    # below both, so it is the first thing to fire, not the last.
    OVERHEAT = (m_heat + 0 > 0) ? m_heat + 0 : 200
    # Every band is now a consequence of those four numbers rather than a
    # remembered figure. PARK_AT: park+clear (~23k for the park itself) beats
    # eating one gap at context x 2. CLEAR_PK / CLEAR_NO: after a gap, the
    # rewrite is already due, so it is only restart-vs-carry. CUT_PK / CUT_NO:
    # a restart pays once carrying it for one session of cycles costs
    # more than paying the floor again.
    PARK_AT  = (RESTART_PARK + 23) / 2
    CLEAR_PK = RESTART_PARK / 2
    CLEAR_NO = RESTART_NO / 2
    CUT_PK   = FLOOR + RD_PARK + RESTART_PARK / (REM * RPC * 0.1)
    CUT_NO   = FLOOR + RD_NO   + RESTART_NO   / (REM * RPC * 0.1)
    # The bands have to stay in order for the ladder to mean anything. On a thin
    # history the measured crossover can land above a cut bar, and a rung that
    # overtakes the one above it is worse than no rung - so it is clamped into
    # the gap it belongs in rather than being drawn out of sequence.
    if (OVERHEAT <= PARK_AT) OVERHEAT = PARK_AT + 1
    if (OVERHEAT >= CUT_PK)  OVERHEAT = CUT_PK - 1
    n = 0; freshest = 0; fresh_idle = 999999 }

  /^#/ { if ($2 == "hidden") { HID = $3 + 0; HTOT = $4 + 0 } next }

  { n++
    sid[n] = $1; al[n] = $2 + 0; id[n] = $3 + 0; lf[n] = $4 + 0
    cx[n]  = $5 + 0; nm[n] = $6; td[n] = $7; pid[n] = $8; pj[n] = $9
    ti[n]  = $10; cy[n] = $11 + 0; ot[n] = $12 + 0; ol[n] = $13 + 0
    rl[n]  = $14 + 0; uuid[n] = $15; lp[n] = $17
    rn[n]  = $18 + 0; pk[n] = $19 + 0; ck[n] = $20 + 0; ckf[n] = $21
    ckt[n] = $22; cko[n] = $23
    rt[n]  = $25 + 0; gt[n] = $26 + 0; fb[n] = $27 + 0; gp[n] = $28 + 0
    tc[n]  = $29 + 0
    nv[n]  = NV[$1] + 0
    nc[n]  = NC[$1]
    nk[n]  = (nc[n] != "") ? substr(nc[n], 1, NICKW) : nickv(ti[n], lp[n], NICKW, nv[n])
    sfx[n] = (length(nm[n]) > 1) ? substr(nm[n], length(nm[n]) - 1) : "  "
    if (al[n] == 1 && id[n] < fresh_idle) { fresh_idle = id[n]; freshest = n }
    push(n) }

  END {
    # One row, not four. The old banner spent a blank line and a three-row box
    # on a word you already knew - in a pane that was shedding whole sections to
    # fit. What the row carries instead is the pair of facts the tab exists to
    # produce: how many windows want a decision, and what the live ones hold.
    # Both used to sit dim at the bottom of STATE, below the rows they describe.
    nact = 0; ncut = 0; livek = 0; nrun = 0
    for (i = 1; i <= n; i++) {
      if (al[i] != 1) continue
      livek += cx[i] / 1000
      if (rn[i]) nrun++
      u = urank(i)
      if (u >= 2) nact++
      else if (u == 1) ncut++ }
    head = B ttlz("SESSIONS") R
    if (nact > 0)      head = head sprintf("   %s%s %d want%s you now%s", ORG, g_act, nact, (nact == 1 ? "s" : ""), R)
    else if (ncut > 0) head = head sprintf("   %s%s %d cut would pay%s", YEL, g_cut, ncut, R)
    else               head = head sprintf("   %s%s nothing to do%s", D GRN, g_ok, R)
    # The lamp. A row scrolled off the bottom of the list is a turn you cannot
    # see running, and this is the one line that is always on screen - so the
    # count lives here too, moving in step with the markers below it.
    if (nrun > 0)
      head = head sprintf("   %s%s %d working%s", B CYN, (watch ? spin() : here), nrun, R)
    head = head sprintf("   %s%s   %.0fk live%s", D, vv, livek, R)
    if (filt != "") head = head sprintf("   %s/%s%s", CYN, filt, R)
    tail = clock (watch ? (secs + 0 > 0 ? sprintf("   next %ds", secs) : "   reading") : "")
    gap = W - dwid(head) - length(tail); if (gap < 1) gap = 1
    printf "  %s%s%s%s%s\n", head, rep(" ", gap), D, tail, R

    # A filter that matches nothing looks exactly like a machine with nothing
    # running on it - which is the one reading that would send you off to check
    # a terminal that was fine all along.
    if (n == 0) {
      if (filt != "")
        printf "  %snothing matches%s %s%s%s   %s/ then enter clears it%s\n\n", D, R, CYN, filt, R, D, R
      else printf "  %sno sessions found%s\n\n", D, R
      exit }
    if (sel > n) sel = n

    # What fits. The pane redraws in place and cannot scroll, so a line past the
    # last row is not merely awkward, it is gone - and nothing here used to
    # check. Everything below is drawn from these three flags, decided once,
    # rather than each block guessing.
    #
    # The shedding order is by how much each line is worth when the window is
    # short: the key is reference material you read once, a description under a
    # row with nothing to do is a line saying so, and the rows themselves are
    # the last thing to give. Cost, not decoration, goes last.
    # Chrome, counted rather than guessed: 1 blank + 3 title + 1 top rule +
    # 1 header + 1 divider + 2 state + 1 divider + 2 do + 1 closing rule = 13,
    # and the key section is 5 more when it is shown. It used to reserve 12 flat
    # for both cases, which is why a short window still overflowed after it had
    # finished shedding.
    # DESCS starts at 1, not 2. A description under a row with nothing to do
    # was a line spent restating the cache column and then saying "nothing to
    # do" - the quiet rows are exactly the ones that should recede, and the
    # lines they were taking now go to the rows that want a decision.
    MINLIST = 3                           # rows of list the panel may never take
    SHOWKEY = 1; DESCS = 1                # 1 only rows that want it, 0 none
    # Chrome, counted rather than guessed: 1 title + 1 top rule + 1 header +
    # 1 divider + 2 state + 1 divider + 2 do + 1 closing rule = 10, the key
    # section 5 more, and 2 of slack. The banner used to be four rows of that.
    budget = rows - 17
    # The panel is elastic. It used to reserve a flat 16 whatever the window
    # was, so at 24 rows the budget went NEGATIVE, ROWCAP with it, and the pane
    # drew a header, no rows at all, and the string "-7 of 2 shown". Now it
    # shrinks to a compact form first and never takes the last of the list.
    # Two heights, because a selection now draws one of two things: the brief
    # (four lines, five when the advice wraps) or the whole panel. Only d asks
    # for the second, so only d spends a third of the window on it.
    DTLC = 0
    if (sel > 0) {
      dh = dtl ? 16 : 7
      if (dtl && budget - dh < MINLIST) { DTLC = 1; dh = 9 }
      if (budget - dh < MINLIST) dh = budget - MINLIST
      if (dh < 5) dh = 5
      budget -= dh }
    # The local-runtime block costs a divider plus its rows, so it is counted
    # like everything else rather than drawn and hoped for.
    OLLCAP = 5
    nollr = (ollrows == "") ? 0 : split(ollrows, OLLR, "\n")
    SHOWOLL = (nollr > 0)
    ollh = SHOWOLL ? 1 + ((nollr > OLLCAP) ? OLLCAP + 1 : nollr) : 0
    budget -= ollh
    want = n; for (i = 1; i <= n; i++) if (urank(i) > 0) want++
    if (want > budget && SHOWKEY) { SHOWKEY = 0; budget += 3 }
    if (want > budget && SHOWOLL) { SHOWOLL = 0; budget += ollh }
    if (want > budget) { DESCS = 0; want = n }
    ROWCAP = (want > budget) ? budget : n
    # The floor the whole block exists to defend. A list you cannot see is not a
    # list, so whatever the arithmetic above concluded, at least one row draws.
    if (ROWCAP < 1) ROWCAP = 1
    if (ROWCAP > n) ROWCAP = n
    # A viewport, not a truncation. What did not fit used to be dropped on the
    # floor with a count of the loss; now the window slides to keep the
    # selection inside it, so every row is reachable with j/k however short the
    # terminal is.
    TOPI = 1
    if (ROWCAP < n && sel > 0) {
      TOPI = sel - int((ROWCAP - 1) / 2)
      if (TOPI + ROWCAP - 1 > n) TOPI = n - ROWCAP + 1
      if (TOPI < 1) TOPI = 1 }

    # 8, because that is what the row prefix actually measures: two of gutter,
    # the run mark, the verdict glyph, their two spaces and the park/fail-safe
    # pair. It said 6 for as long as the lamp column has existed, which is why
    # every header sat two columns left of the data under it.
    pt(sprintf("%s%s%s %s%d live%s%s%s", D, hd("sessions"), R, D, nlive(), R, \
      (srtname != "") ? sprintf("%s   by %s%s", D, srtname, R) : "", \
      (ROWCAP < n) ? sprintf("%s   %d-%d of %d   %sj k scrolls%s", D, TOPI, TOPI + ROWCAP - 1, n, D, R) : ""))
    pl(sprintf("%s%s%s%s%s%s%s%s%s%s", D, rep(" ", 8), pad(hd("session"), NAMEW),
       (GW ? pad(hd("grade"), GW) : ""),
       pad(hd("context"), CBW + 10), (HW ? pad(hd("heat"), HW) : ""),
       (COW ? pad(hd("cost"), COW) : ""),
       pad(hd("growth"), SPW + 1), padl(hd("cache"), 5), R))
    for (i = TOPI; i <= n; i++) {
      # A rule where the live rows stop. Closed sessions were reading as more
      # table when they are really a footnote - nothing about them is a
      # decision any more - and on --all they outnumber the live rows ten to
      # one. One dim rule puts the eye back on the top of the list.
      if (i >= TOPI + ROWCAP) break
      if (al[i] == 0 && !shownclosed) {
        shownclosed = 1
        pl(sprintf("%s%s %s %s%s", D, rep(ph, 2), hd("closed"), \
          rep(ph, W - 6 - length(hd("closed"))), R)) }
      row(i) }
    # Said out loud, because "12 closed" reads as "12 sessions have ever closed"
    # and that is exactly the belief this footer exists to prevent.
    if (HID > 0)
      pl(sprintf("    %s+%d older closed sessions of %d (TOKEN_CLOSED_MAX=%d)%s", \
        D, HID, HTOT, HTOT - HID, R))

    # Two lines, where there used to be six. The old block re-taught every
    # column on every frame, which is a manual stapled to an instrument: a pane
    # you glance at is not read six lines deep, so all six were noise most of
    # the time and the one line that mattered was buried among them. What
    # survives is the part that changes meaning row to row - the markers, and
    # the three bar ladders as bare swatches. The prose that explains them is
    # behind ? in watch mode and in --help everywhere else.
    anyrun = 0; anypark = 0; anytrend = 0; anystale = 0
    for (i = 1; i <= n; i++) {
      if (rn[i]) anyrun = 1
      if (pk[i]) anypark = 1
      if (pstale(i)) anystale = 1
      if (cy[i] > 1) anytrend = 1 }
    anylast = (freshest > 0 && !rn[freshest])

    if (SHOWKEY) {
    pmid(D hd("key") R)
    leg = sprintf("%s%s%s %s%s%s %s%s%s  %sact / cut pays / ok%s", \
      ORG, g_act, R, YEL, g_cut, R, D GRN, g_ok, R, D, R)
    if (anyrun)  leg = leg sprintf("   %s%s%s %srunning%s", B CYN, (watch ? spin() : here), R, D, R)
    if (anylast) leg = leg sprintf("   %s%s%s %slatest%s", BLU, last, R, D, R)
    if (anypark) leg = leg sprintf("   %s%s%s %sparked%s", BLU, park, R, D, R)
    # Width-guarded like every other clause on this line: the frame is drawn per
    # line, so a legend that outgrows it does not wrap, it punches the right
    # border off.
    if (anystale && dwid(leg) < W - 14)
      leg = leg sprintf("   %s%s%s %sbehind%s", YEL, park, R, D, R)
    pl(leg)

    # Each swatch carries its own threshold, rather than four bare numbers
    # trailing one four-block bar and leaving you to pair them up by position.
    # Five swatches, because ctxcol() has five bands - the red one above the
    # unparked cut bar was missing, so the ladder stopped one rung short of the
    # only colour on it that means money is already on the floor. Each number
    # is where its swatch ENDS; the last has none because it has no top.
    # Only the rungs you are standing on, plus the next one up. Six swatches was
    # the whole ladder redrawn every frame whatever was on screen - four of them
    # describing colours no row had - and it is the widest line in the block. A
    # legend for something not present is not a legend, it is a manual.
    split(FLOOR " " PARK_AT " " OVERHEAT " " CUT_PK " " CUT_NO, BEND, " ")
    BCOL[1] = D GRN; BCOL[2] = GRN; BCOL[3] = YEL
    BCOL[4] = ORG;   BCOL[5] = ORG; BCOL[6] = RED
    maxb = 1
    for (i = 1; i <= n; i++) {
      if (al[i] != 1) continue
      c = cx[i] / 1000; b = 6
      for (j = 1; j <= 5; j++) if (c < BEND[j]) { b = j; break }
      if (b > maxb) maxb = b }
    topb = (maxb < 6) ? maxb + 1 : 6
    leg = sprintf("%sctx%s", D, R)
    for (j = 1; j <= topb; j++)
      leg = leg sprintf(" %s%s%s%s", BCOL[j], full, D, \
        (j == 6) ? "+" : sprintf("%.0f%s", BEND[j], (j == topb) ? "k" : ""))
    leg = leg R
    if (COW && dwid(leg) < W - 26)
      leg = leg sprintf("   %scost%s %s%s%s%s%s%s%s %sout write read%s", D, R, GRN, full, ORG, full, BLU, full, R, D, R)
    if (anytrend && dwid(leg) < W - 22)
      leg = leg sprintf("   %sgrowth%s %s%s%s%s%s %svs %.0fk%s", D, R, BLU, SP[2], SP[5], SP[8], R, D, gbud / 1000, R)
    if (GW && anytrend && dwid(leg) < W - 20)
      leg = leg sprintf("   %sABC%s %sspend prod ctl%s", B, R, D, R)
    pl(leg)
    # Two lines, where there were four. The heat sentence and the under-the-floor
    # sentence were both prose explaining a column, printed on every frame - and
    # prose is what ? is for. The row that is under the floor already says "carry
    # on, under the bar" on its own resume line, which is the same fact where you
    # were actually looking.
    pl(sprintf("%s%s%s", D, (watch ? "j k  select      d  expand      ?  the full column key" : "--help  the full column key"), R))
    }

    # Three lines, and they are the three questions the pane exists to answer:
    # what is on the machine right now, what it has cost, and whether that is
    # normal. The local-runtime lines used to sit here too - a free runtime
    # reporting free work, in the block whose whole subject is what is being
    # paid for. TOKEN_SHOW_OLLAMA=1 brings both back.
    pmid(D hd("state") R)
    pl(summary())
    t = spend();   if (t != "") pl(t)
    t = overall(); if (t != "") pl(t)
    if (ollv + 0 == 1) { t = ollama(); if (t != "") pl(t) }
    # The local runtime as a list of sessions rather than one summed line. Kept
    # under STATE because it is the same question one runtime over, and shed
    # before the rows are - a Claude window can cost you money while you are not
    # looking; a finished ollama run cannot.
    if (ollv + 0 == 1 && SHOWOLL && nollr > 0) {
      pmid(D hd("ollama") R)
      for (oi = 1; oi <= nollr && oi <= OLLCAP; oi++) {
        split(OLLR[oi], OF, "|")
        pl(sprintf("%s%s%s %s%s%s  %s%s%s  %s%d call%s%s  %s%s%s  %s%.1fk in %s %.1fk gen%s  %s%.1fs avg%s  %s%s ago%s", \
          D BLU, g_ok, R, B, pad(OF[2], 14), R, D, vv, R, \
          GRN, OF[3], (OF[3] + 0 == 1 ? "" : "s"), R, \
          D, ell(OF[4], 20), R, \
          D, OF[5] / 1000, vv, OF[6] / 1000, R, \
          D, OF[7] / 1000, R, D, ago(int(OF[1] / 60)), R)) }
      if (nollr > OLLCAP)
        pl(sprintf("    %s+%d more local session%s%s", D, nollr - OLLCAP, \
          (nollr - OLLCAP == 1 ? "" : "s"), R)) }
    if (sel == 0 && acts != "") {
      pmid(D hd("do") R)
      na = split(acts, aa, "\n")
      for (i = 1; i <= na; i++) if (aa[i] != "") pl(aa[i]) }
    pb()
    if (sel > 0) { if (dtl) detail(sel, DTLC); else brief(sel) }
    if (watch) {
      if (helpv + 0 == 1) {
        # The legend the overview used to print unconditionally. It belongs
        # here: it is read once, when you are learning the pane, and never
        # again - and every frame it spent on screen was a frame the rows had
        # to share with it.
        printf "\n  %scolumns%s\n", B, R
        printf "    %s%s%s%s   %sone glyph per row, off the same ladder the advice below is written from\n", \
          ORG, g_act, R, rep(" ", 2), D
        printf "    %s%s%s%s%s%s%s   size and nothing else: %.0fk floor %s %.0fk park first %s %.0fk cut if parked %s %.0fk cut%s\n", \
          D GRN, full, GRN, full, YEL, full, ORG, FLOOR, vv, PARK_AT, vv, CUT_PK, vv, CUT_NO, R
        printf "    %s%s%s%s%s%s%s   spent so far: output %s cache writes %s cache reads (modelled)%s\n", \
          GRN, full, ORG, full, BLU, full, D, vv, vv, R
        printf "    %s%s%s%s%s   growth per cycle, full block is the %.0fk budget %s %s%s%s over growth %s %s%s%s over output%s\n", \
          BLU, SP[2], SP[5], SP[8], D, gbud / 1000, vv, RED, SP[8], D, vv, YEL, SP[8], D, R
        printf "    %s1.0x%s%s  heat: what a cycle pays to HAVE this context %s what that cycle produced.\n", \
          ORG, R, D, vv
        printf "          Over 1.0 the window costs more than it returns - small cycles raise it as surely\n"
        printf "          as a big context does, so the fix is sometimes heavier prompts, not a fresh session%s\n", R
        printf "    %s%s%s%s  a /park checkpoint on disk. %s%s%s%s means the session has worked on past it -\n", \
          BLU, park, R, D, YEL, park, R, D
        printf "          the file resumes an older state, so /park again before you /clear (>%dm of work after)%s\n", ckstale, R
        printf "    %sSPEND%s%s  weighted input-equivalents priced at the API input rate. The %% is against\n", B, R, D
        printf "          TOKEN_PLAN_5H_USD / TOKEN_PLAN_WEEK_USD, set in token-sessions-launch.sh%s\n", R
        printf "    %sABC%s%s   spend %s production %s control, against your own median (%.0fk/cyc, %.0f%% output).\n", \
          B, R, D, vv, vv, p_wpc, p_prod
        printf "          spend is measured ABOVE the ~%.0fk floor, so cycle 1 is not punished for it%s\n", FLOOR, R
        # Both this list and the strip below it are printed from the one key
        # table the shell passes in, so a key cannot work while appearing in
        # neither - which is how d, D, g and G went undocumented for months.
        printf "\n  %skeys%s   %sstate: bell %s %s detail %s%s\n", B, R, D, \
          (bell ? "on" : "off"), vv, (dtl ? "on" : "off"), R
        nkt = split(keytab, KL, "\n")
        for (ki = 1; ki <= nkt; ki += 2) {
          split(KL[ki], KA, "|")
          kline = sprintf("    %s%s%s %s%s%s", B, pad(KA[1], 4), R, D, pad(KA[2], 48), R)
          if (ki + 1 <= nkt) {
            split(KL[ki + 1], KB, "|")
            kline = kline sprintf("  %s%s%s %s%s%s", B, pad(KB[1], 4), R, D, KB[2], R) }
          print kline } }
      else {
        # The strip is the same table, filtered to the keys that earned a label,
        # so it can never drift from the overlay above it.
        nkt = split(keytab, KL, "\n"); kline = ""
        for (ki = 1; ki <= nkt; ki++) {
          split(KL[ki], KA, "|")
          if (KA[3] == "") continue
          kline = kline sprintf("%s%s%s %s%s%s   ", B, KA[1], R, D, KA[3], R) }
        if (!bell) kline = kline sprintf("%sbell off%s   ", D, R)
        # An action you just took reports back where you are looking, not in a
        # log you would have to go and find.
        # An update sits to the LEFT of the key strip and stays there until it
        # is taken or dismissed, because unlike a flash it is not reporting
        # something you just did - it is asking for a decision.
        if (upd != "") kline = sprintf("%s%s update %s available%s %su takes it, U dismisses%s   %s",
                                       YEL, arrow, upd, R, D, R, kline)
        if (flash != "") kline = sprintf("%s%s%s   %s", GRN, flash, R, kline)
        printf "\n  %s\n", kline } }
    else printf "\n" }

  # Size, and nothing but size.
  #
  # This used to be urgency() - context and cache state together - so a row
  # changed colour without changing length, and the bar and its colour were
  # answering two different questions at once. Cache state has a column of its
  # own two along; the combination of the two is what the advice line is for.
  # The bands are the ones that are true whatever the cache is doing: under the
  # parking bar there is nothing to think about, past it a gap starts to cost
  # more than parking, and the two cut bars are where a fresh session pays for
  # itself with and without a checkpoint on disk.
  function ctxcol(i,   c) {
    if (al[i] == 0) return GRY
    # Drawn only for the row awaiting confirmation, so it can never be
    # mistaken for a property of the session.
    if (delconf != "" && sid[i] == delconf) {
      if (al[i] == 1)
        printf "    %s%s%s%sthe log of a live session cannot be removed%s   %sits process is still writing to it%s\n", GRY, pad("delete", 9), R, RED, R, D, R
      else
        printf "    %s%s%s%sD again moves this log to deleted-sessions/%s   %sany other key cancels%s\n", GRY, pad("delete", 9), R, RED, R, D, R
    }
    c = cx[i] / 1000
    if (c >= CUT_NO)   return RED
    if (c >= CUT_PK)   return ORG
    # The overheat bar earns its own rung: between it and the cut bar the window
    # is not yet worth paying the floor again for, but it has already stopped
    # returning more than it costs to hold.
    if (c >= OVERHEAT) return ORG
    if (c >= PARK_AT)  return YEL
    # Below the floor the ladder has one more rung, and it is the only one that
    # is good news rather than merely quiet: a fresh session would START here,
    # so there is no version of clearing that leaves you smaller. Dim green and
    # not a colour of its own on purpose - it is still the green band, and the
    # bar is still size and nothing else.
    if (c < FLOOR)    return D GRN
    return GRN }

  # What this session has spent so far, split by where it went. The colours are
  # the point of the column: green is output - the work - and orange and blue
  # are the two ways a window charges rent for merely existing. A row that is
  # mostly orange and blue has been carried rather than used.
  #
  # p[1] output, p[2] cache writes, p[3] cache reads, p[0] the total, all in
  # input-equivalents. Output and writes are counted off the history; reads are
  # MODELLED (this window x requests per cycle) because nothing on disk records
  # them per cycle. That is also why the column is deliberately coarse.
  function cparts(i, p) {
    p[1] = ot[i] * 5; p[2] = rt[i] * 2; p[3] = cx[i] * RPC * 0.1 * cy[i]
    p[0] = p[1] + p[2] + p[3]
    return (cy[i] > 0 && p[0] > 0) }

  # Three shares of one bar, in the same colours the cost column uses.
  function splitbar(a, b, c, wd,   t, na, nb, nc) {
    t = a + b + c; if (t <= 0) return rep(empt, wd)
    na = int(a / t * wd + 0.5); nb = int(b / t * wd + 0.5)
    if (na + nb > wd) nb = wd - na
    if (nb < 0) nb = 0
    nc = wd - na - nb
    return GRN rep(full, na) ORG rep(full, nb) BLU rep(full, nc) R }

  # med / last / peak growth for this session, plus how many cycles went over
  # budget - read off the very same "growth:output" pairs the sparkline draws,
  # so the column and the panel can never disagree about a session.
  function gstats(i, g,   a, m, j, k, p, v, sv) {
    m = split(td[i], a, " ")
    if (m < 1) return 0
    g[2] = 0; g[4] = 0
    for (j = 1; j <= m; j++) {
      p = index(a[j], ":")
      sv[j] = (p ? substr(a[j], 1, p - 1) : a[j]) + 0
      if (sv[j] > g[2]) g[2] = sv[j]
      if (sv[j] > gbud) g[4]++ }
    g[3] = sv[m]
    for (j = 2; j <= m; j++) {
      v = sv[j]; for (k = j - 1; k >= 1 && sv[k] > v; k--) sv[k + 1] = sv[k]; sv[k + 1] = v }
    g[1] = (m % 2) ? sv[int(m / 2) + 1] : (sv[m / 2] + sv[m / 2 + 1]) / 2
    return 1 }

  # How hard this window is working for its keep: what a cycle pays merely to
  # HAVE this context (the modelled cache reads) against what a cycle of it
  # actually produced. Under 1 the work is worth more than the rent; over 1 the
  # window has started costing more than it returns, and no amount of cache
  # warmth fixes that - which is exactly why it is a separate signal from the
  # cache column and from the cut bars.
  # A checkpoint that no longer describes the session it belongs to. Both halves
  # are already on the row: ck is how long ago the file was written, id how long
  # ago the last turn was - so the gap between them is work done AFTER parking,
  # and the checkpoint resumes a state that far back.
  #
  # This matters more than it looks. The advice for a parked window is "/clear,
  # the gap costs nothing", and that is only true while the checkpoint is
  # current; against a stale one it is advice to throw away the last hour. A
  # closed session is never stale - the file is its final record, and there is
  # no session left to have moved on from it.
  function pstale(i) {
    return (pk[i] && al[i] == 1 && ck[i] - id[i] >= ckstale) }
  function pbehind(i) { return ago(ck[i] - id[i]) }

  function hot(i,   work) {
    # Three cycles and a window past the floor before this says anything. Under
    # either, the denominator is one or two prompts of output and the ratio is
    # noise wearing a decimal point - a 32k session that had not started working
    # yet was reading 37.8x, which is not a window that has stopped paying, it
    # is a window that has not begun. Overheating is a claim about a big window
    # returning too little, so it needs a big window to be about.
    if (cy[i] < 3 || ot[i] <= 0 || cx[i] / 1000 < FLOOR) return 0
    work = ot[i] / cy[i] * 5
    if (work <= 0) return 0
    return cx[i] * RPC * 0.1 / work }
  function hotcol(h) {
    return (h >= 1.5) ? RED : (h >= 1.0) ? ORG : (h >= 0.7) ? YEL : GRN }
  function hcell(i,   h) {
    if (HW == 0) return ""
    h = hot(i)
    if (h <= 0) return rep(" ", HW)
    if (al[i] == 0) return GRY padl(sprintf("%.1fx", h), HW - 1) R " "
    return hotcol(h) padl(sprintf("%.1fx", h), HW - 1) R " " }

  # The resume: the state of this window in as few words as it can be put, with
  # the verdict glyph in front of it. This is the line the table used to spend
  # on a truncated copy of the first prompt - which the nickname is already made
  # of, so it was the same words twice while the thing you actually needed (what
  # to do about this row) was only ever said in a paragraph further down.
  function resume(i,   u, h, s) {
    if (al[i] == 0) return "closed"
    u = urank(i); h = hot(i)
    s = (lf[i] > 0) ? sprintf("%dm cache", lf[i]) : "cold"
    if (pk[i]) s = s (pstale(i) ? R YEL ", parked " pbehind(i) " behind" R D : ", parked")
    if (u == 3)      s = s D "  " ORG "clear before you type" R
    else if (u == 2) s = s D "  " ORG (lf[i] > 0 ? "park before you go" : "clear, it is parked") R
    else if (u == 1) s = s D "  " YEL (lf[i] > 0 ? "a cut would pay" : "carry on, under the bar") R
    else             s = s D "  nothing to do" R
    if (h >= 1 && al[i] == 1)
      s = s D "  " hotcol(h) sprintf("overheating %.1fx", h) R
    return D s R }

  function ccell(i,   p, no, nw, nr, s) {
    if (COW == 0) return ""
    if (!cparts(i, p)) return rep(" ", COW)
    s = ""
    if (CBAR > 0) {
      no = int(p[1] / p[0] * CBAR + 0.5); nw = int(p[2] / p[0] * CBAR + 0.5)
      if (no + nw > CBAR) nw = CBAR - no
      if (nw < 0) nw = 0
      nr = CBAR - no - nw
      s = GRN rep(full, no) ORG rep(full, nw) BLU rep(full, nr) R " " }
    return s ((al[i] == 0) ? GRY : "") padl(hum(p[0]), 6) R " " }

  # A turn in flight, as one column that moves. The marker used to be a static
  # arrow, which says "this was running when the disk was last read" in exactly
  # the same ink as "this is running now" - and a pane you glance at cannot tell
  # a stale frame from a live one unless something on it is moving.
  #
  # Built out of the spark ramp rather than a new glyph, on purpose: those eight
  # are already proven to render one column wide in this font, and a spinner
  # made of braille or quadrant circles is exactly the kind of glyph Consolas
  # does not have - it would fall back to another face, come out double-width,
  # and take the whole table apart. It also survives --ascii and --no-color,
  # because the shape changes rather than the colour.
  #
  # tick advances once per redraw, and the loop only redraws four times a second
  # while something is actually running - so the animation costs nothing on a
  # quiet machine.
  function spin(   pu, k) {
    split("1 2 4 6 8 7 5 3", pu, " ")
    k = (tick % 8) + 1
    return SP[pu[k]] }

  function row(i,   c, cbar, cc, kc, klab, mark, pm, fm, gut, nc, d, t, dtlr) {
    c = cx[i] / 1000
    cc = ctxcol(i)
    cbar = bar(c / ctxmax, CBW)

    # Minutes and a colour, which is the whole of what the cache has to say.
    # COLD used to be red on every row, which is the table shouting at a window
    # that has nothing to be done about it: below the clear-vs-carry bar the
    # rewrite is real and carrying on is still the cheapest move there is. The
    # advice line has always said so - the colour just was not listening to it.
    if (al[i] == 0)       { kc = GRY; klab = "-" }
    else if (lf[i] <= 0)  { kc = urgency(i); klab = "COLD" }
    else if (lf[i] <= 10) { kc = ORG; klab = sprintf("%dm", lf[i]) }
    else if (lf[i] <= 25) { kc = YEL; klab = sprintf("%dm", lf[i]) }
    else                  { kc = GRN; klab = sprintf("%dm", lf[i]) }

    # A moving bar means a turn is in flight; a hollow arrow only means this is
    # the session touched most recently. They coincide most of the time, which
    # is why they share a column rather than costing two - but they are two
    # glyphs and not one glyph in two colours, so --no-color still tells them
    # apart. The one-shot form has no second frame to animate into, so there it
    # stays the solid arrow it always was.
    mark = rn[i] ? B CYN (watch ? spin() : here) R \
                 : ((i == freshest) ? BLU last R : " ")
    # Yellow rather than blue when the checkpoint is behind the session: same
    # glyph, so --no-color loses only the warning and not the fact of a park.
    pm   = pk[i] ? (pstale(i) ? YEL : BLU) park R " " : "  "
    # Compact drops the description line, and with it the only place the verdict
    # is written - so it borrows the fail-safe slot, which has been two blank
    # columns for as long as the fail-safe has been retired. Width-neutral, so
    # the table does not reflow between the two modes.
    fm   = compact ? actg(i) " " : "  "
    gut  = (i == sel) ? CYN selbar R " " : "  "
    # Three states in one column of ink: selected wins, then working, then
    # closed. A session with a turn in flight is the one row on the pane whose
    # numbers are about to change, so it reads bright even when it is not the
    # row you have your cursor on.
    nc   = (i == sel) ? B CYN : (rn[i] ? B : ((al[i] == 0) ? GRY : ""))

    # Nickname, then the last two characters of the derived name the CLI keeps -
    # the only thing tying this row back to what the client calls the session.
    pl(sprintf("%s%s %s%s%s%s %s%s%s %s%s%s%s %s%6.1fk%s  %s%s%s%s%s %s%s%s",
      gut, mark, pm fm, nc, pad(nk[i], NAMEW - 3), R, GRY, sfx[i], R,
      gcell(i), cc, cbar, R, cc, c, R,
      hcell(i), ccell(i), BLU, spark(td[i]), R,
      kc, padl(klab, 5), R))
    # The description line. It used to be a truncated copy of the first prompt,
    # which is the same words the nickname two columns left is built out of -
    # so the row spent its second line saying what it had already said, and the
    # thing you actually need (what to do about this window) was only ever
    # written as a paragraph further down the pane. It carries the verdict now:
    # the glyph, then the state in as few words as it goes, then - only in the
    # detailed view - the prompt and the advice behind it.
    # d expands what you are looking at, not the whole list: with a row selected
    # it is that row (and the panel below), with nothing selected it is every
    # row, which is what it always was.
    dtlr = (dtl && (sel == 0 || i == sel))
    if (compact || (al[i] == 0 && !dtlr)) return
    # DESCS is the height budget talking: 0 drops the line, 1 keeps it only for
    # rows that actually want something done, 2 keeps it everywhere.
    if (DESCS == 0 || (DESCS == 1 && urank(i) <= 0)) return
    pl(sprintf("     %s %s", actg(i), resume(i)))
    if (!dtlr) return
    pltxt(wrap(ti[i], W - 12, ""), 7, D, "")
    t = tip(i, 1)
    if (t != "") pltxt(wrap(t, W - 14, ""), 7, D, urgency(i) arrow R " ") }

  # wrap() hands back a block of newline-separated lines; each of them still has
  # to be framed, so this splits and feeds them through pl() one at a time.
  # Without it a wrapped paragraph would punch straight through the right-hand
  # border - which is the whole failure the panels were meant to end.
  # A wrapped paragraph, framed one line at a time. wrap() returns a single
  # string with newlines inside it AND a trailing one, so handing that to pl()
  # whole punched through the right-hand border - and because the colour reset
  # was appended after that last newline, the reset arrived as a line of its own
  # and printed as a blank row inside the panel. So colour is applied per line
  # here, never wrapped around the block.
  #
  # lead is what hangs in the margin of the FIRST line (an arrow, typically);
  # continuations get two spaces so they align under the text rather than under
  # the arrow.
  function pltxt(block, ind, col, lead,   a, m, j, g) {
    m = split(block, a, "\n")
    for (j = 1; j <= m; j++) {
      if (a[j] == "") continue
      g = (lead == "") ? "" : ((j == 1) ? lead : "  ")
      pl(rep(" ", ind) g col a[j] R) }
    return "" }

  # Cold is two different situations wearing one word, and they want opposite
  # things done to them. A cold window with a checkpoint on disk is finished
  # business - /clear it and nothing is lost. A cold window without one is the
  # only line here that is still costing a decision. Counting them together hid
  # the second behind the first.
  # Cold is two different situations wearing one word, and they want opposite
  # things done to them. A cold window with a checkpoint on disk is finished
  # business - /clear it and nothing is lost. A cold window without one is the
  # only line here that is still costing a decision. Counting them together hid
  # the second behind the first.
  #
  # Built twice: once with the full labels, and if that overruns the panel, once
  # with the short ones. It used to keep a parallel character count by hand
  # (re-sprintf-ing every clause a second time without its colours, purely to
  # measure it), which is what made the two ladders drift apart. dwid() measures
  # the finished string, so the fallback is now the same code with a shorter
  # word list rather than a second copy of the logic.
  function summary(   i, w, wt, cd, ct, pc, pt, fc, ft, s) {
    for (i = 1; i <= n; i++) {
      if (al[i] != 1) continue
      if (lf[i] > 0)  { w++;  wt += cx[i] / 1000 }
      else if (pk[i]) { pc++; pt += cx[i] / 1000 }
      # A cold window under the clear-vs-carry bar is not stranded, and calling
      # it that was the summary contradicting its own advice line. The rewrite
      # is booked either way; the only question a cold window asks is whether
      # clearing beats carrying, and under the bar it does not.
      else if (cx[i] / 1000 < CLEAR_NO) { fc++; ft += cx[i] / 1000 }
      else            { cd++; ct += cx[i] / 1000 } }
    s = sumline(w, wt, pc, pt, fc, ft, cd, ct, 0)
    return (dwid(s) > W - 2) ? sumline(w, wt, pc, pt, fc, ft, cd, ct, 1) : s }

  function sumline(w, wt, pc, pt, fc, ft, cd, ct, terse,   s) {
    s = terse ? sprintf("%s%d warm%s %.0fk", GRN, w, R, wt) \
              : sprintf("%s%d warm%s  %.0fk live  %s(%.0fk if it all lapses)%s", GRN, w, R, wt, D, wt * 2, R)
    if (pc > 0) s = s sprintf("   %s%s%s   %s%d parked%s%s %.0fk %s%s%s", D, vv, R, BLU, pc, \
      (terse ? "" : " cold"), R, pt, D, (terse ? "clear" : "ready to clear"), R)
    if (fc > 0) s = s sprintf("   %s%s%s   %s%d %s%s %.0fk %scarry on%s", D, vv, R, YEL, fc, \
      (terse ? "under the bar" : "cold under the bar"), R, ft, D, R)
    if (cd > 0) s = s sprintf("   %s%s%s   %s%d cold%s %.0fk %sstranded%s", D, vv, R, RED, cd, R, ct, D, R)
    return s }

  # The three axes again, but for every session over the last seven days, and
  # graded against the same corpus medians one row is graded against - so the
  # overall line and the cell on a row can never mean different things. The arrow is
  # the half worth watching: a C that used to be a D is a week that went right,
  # and one session on its own is far too noisy to read that off.
  function overall(   g1, g2, g3, h1, h2, h3, s) {
    if (o_n + 0 < 5) return ""
    g1 = grade(o_wpc, p_wpc, 1);   h1 = grade(v_wpc, p_wpc, 1)
    g2 = grade(o_prod, p_prod, 0); h2 = grade(v_prod, p_prod, 0)
    g3 = ctlgrade(o_ctl);          h3 = ctlgrade(v_ctl)
    s = sprintf("%sOVERALL%s %s7d%s   ", B, R, D, R)
    s = s gpair(g1, h1, "spend") "   " gpair(g2, h2, "prod") "   " gpair(g3, h3, "control")
    return s sprintf("   %s%d cycles%s", D, o_n, R) }

  # The Claude-vs-Ollama split, sat directly under OVERALL because it is the same
  # question one axis over: of everything a model GENERATED in the last 7 days, what
  # share came off the free local path instead of the paid one. Silent until the first
  # ollama-run.sh call - a machine that has never offloaded has nothing to report and
  # should not carry a zero row.
  function ollama(   tot, pct, s) {
    if (OLL_CALLS + 0 < 1) return ""
    tot = (OLL_PROMPT + OLL_EVAL) / 1000
    pct = (CL_OUT_7D + OLL_EVAL > 0) ? OLL_EVAL * 100 / (CL_OUT_7D + OLL_EVAL) : 0
    s = sprintf("%sOLLAMA%s %s7d%s   ", B, R, D, R)
    s = s sprintf("%s%d%s calls   %s%.0fk%s local %s(in %.0fk + gen %.0fk)%s", \
          GRN, OLL_CALLS, R, GRN, tot, R, D, OLL_PROMPT / 1000, OLL_EVAL / 1000, R)
    s = s sprintf("   %s%.0f%%%s of generation offloaded   %sfree%s", B, pct, R, D GRN, R)
    return s }

  # What this has actually cost, which until now the pane could only answer by
  # switching tabs - and the tab is eleven sections deep, which is not a glance.
  #
  # Two windows because they are two questions. 5h is "am I about to run into a
  # limit"; 7d is "is this week normal". Both are the weighted input-equivalents
  # every other number here is denominated in, priced at the API input rate so
  # they can be compared against a plan at all.
  #
  # The bar and the percentage appear only when there is a ceiling to be a
  # percentage OF. TOKEN_PLAN_5H_USD / TOKEN_PLAN_WEEK_USD live in
  # token-sessions-launch.sh and need calibrating against /usage once;
  # uncalibrated, this reports the spend and declines to invent a limit.
  function money(d) {
    return (d >= 100) ? sprintf("$%.0f", d) : (d >= 10) ? sprintf("$%.1f", d) : sprintf("$%.2f", d) }
  function planc(f) {
    return (f >= 1) ? RED : (f >= 0.85) ? ORG : (f >= 0.6) ? YEL : GRN }
  function window(lab, wk, cap,   d, f, s) {
    d = wk * 1000 * price / 1000000
    s = sprintf("%s%s%s %s", D, lab, R, money(d))
    if (cap + 0 <= 0) return s
    f = d / cap
    return s sprintf(" %s%s%s %s%.0f%%%s", planc(f), bar(f, 6), R, planc(f), f * 100, R) }

  function spend(   s, gm, gn, i, g) {
    if (o_7d + 0 <= 0) return ""
    s = sprintf("%sSPEND%s  ", B, R) window("5h", o_5h, plan5) \
        sprintf("   %s%s%s   ", D, vv, R) window("7d", o_7d, planwk)
    # The one ratio that says whether the money bought work or just bought
    # continuity - the same split the per-row cost bar draws, over seven days.
    if (o_prod + 0 > 0 && dwid(s) < W - 18)
      s = s sprintf("   %s%.0f%%%s %sinto work%s", \
            (o_prod + 0 >= p_prod) ? GRN : YEL, o_prod, R, D, R)
    # Growth is per-session by nature, so the pane-wide figure averages the
    # per-window medians - enough to see a day that is reading heavy, without
    # pretending it is one number.
    gn = 0; gm = 0
    for (i = 1; i <= n; i++) if (al[i] == 1 && gstats(i, g)) { gm += g[1]; gn++ }
    if (gn > 0 && dwid(s) < W - 20)
      s = s sprintf("   %sgrowth%s %s%.0fk%s%s/%.0fk%s", D, R, \
            (gm / gn > gbud) ? YEL : GRN, gm / gn / 1000, R, D, gbud / 1000, R)
    return s }

  function gpair(g, h, lab,   a) {
    a = (g < h) ? GRN up R : (g > h) ? RED dn R : D "-" R
    return sprintf("%s%s%s %s%s%s %s", gcol(g), g, R, D, lab, R, a) }

  # The table states facts; these state the move. Every threshold here is
  # DERIVED (PARK_AT / CLEAR_PK / CLEAR_NO / CUT_PK / CUT_NO, in thousands)
  # from the floor and the re-derivation cost measured off token-history.csv,
  # so the advice retunes itself as the history grows instead of quoting a
  # number that was true at one review and never again.
  function tip(i, slot,   c, carry, be) {
    c = cx[i] / 1000
    carry = (c - FLOOR - RD_NO) * RPC * 0.1; if (carry < 0.05) carry = 0.05
    be = int(RESTART_NO / carry + 0.5)
    if (al[i] != 1)
      return (slot == 1) ? "the process is gone - nothing here is being paid for any more." : ""
    if (lf[i] > 0) {
      if (slot == 1) {
        # "Already parked, so clearing is free" is only true against a CURRENT
        # checkpoint. Behind one, the same keystroke throws away everything done
        # since it was written - so the stale wording comes first in both
        # branches, and it asks for a re-park rather than a clear.
        if (lf[i] <= 10 && c >= PARK_AT)
          return !pk[i] \
            ? sprintf("lapses in %dm at %.0fk. /park it now - once it is cold the gap costs ~%.0fk.", lf[i], c, c * 2) \
            : pstale(i) \
            ? sprintf("lapses in %dm at %.0fk and the checkpoint is %s behind - /park again, THEN /clear.", lf[i], c, pbehind(i)) \
            : sprintf("lapses in %dm at %.0fk and it is already parked - /clear now and the gap costs nothing.", lf[i], c)
        if (c >= PARK_AT)
          return !pk[i] \
            ? sprintf("stepping away for >1h? /park then /clear (~%.0fk) beats carrying it (~%.0fk).", RESTART_PARK + 23, c * 2) \
            : pstale(i) \
            ? sprintf("parked %s ago but %s of work since - /park again before you go, or you resume from the older state.", ago(ck[i]), pbehind(i)) \
            : sprintf("parked at %.0fk. The checkpoint only pays back when you /clear - carry this into a gap and you pay the rewrite AND the park.", c)
        return sprintf("under %.0fk: eating one gap (~%.0fk) is cheaper than parking. Leave it open.", PARK_AT, c * 2) }
      if (slot == 2) {
        if (pk[i] && c >= CUT_PK)
          return sprintf("checkpoint on disk, so cutting pays from here: ~%.0fk once, against ~%.1fk every cycle to carry.", RESTART_PARK, carry)
        if (c >= CUT_NO)
          return sprintf("at %.0fk a fresh session pays off now: ~%.0fk once, against ~%.1fk every cycle to carry.", c, RESTART_NO, carry)
        if (c >= CUT_PK)
          return sprintf("past %.0fk, cutting would pay if you /park first: ~%.0fk against ~%.1fk/cycle. Unparked the bar is %.0fk.", CUT_PK, RESTART_PARK, carry, CUT_NO)
        return sprintf("carrying costs ~%.1fk/cycle and a restart ~%.0fk, so cutting only pays past ~%d more cycles.", carry, RESTART_NO, be) }
      return "" }
    if (slot == 1) {
      if (c >= CLEAR_NO)
        return pk[i] \
          ? sprintf("COLD at %.0fk and parked: /clear BEFORE typing - ~%.0fk against ~%.0fk to carry.", c, RESTART_PARK, c * 2) \
          : sprintf("COLD at %.0fk: /clear BEFORE typing - ~%.0fk against ~%.0fk to carry.", c, RESTART_NO, c * 2)
      if (c >= CLEAR_PK)
        return pk[i] \
          ? sprintf("COLD at %.0fk with a checkpoint: /clear before typing, resume from it (~%.0fk).", c, RESTART_PARK) \
          : sprintf("COLD at %.0fk and not parked: carry on - re-deriving costs ~%.0fk and it is under the clear-vs-carry bar.", c, RD_NO)
      return sprintf("COLD at %.0fk, under the ~%.0fk floor - clearing would only make it bigger.", c, FLOOR) }
    if (slot == 2 && c >= CLEAR_PK)
      return "the rewrite is billed on your NEXT message, so clearing before you type costs nothing."
    return "" }

  # Three numbers, graded against what this machine actually does rather than
  # against a target someone picked. All three come off the same history rows
  # the alerts do, so a session cannot look good here and bad there.
  #
  #   spend       weighted cost per cycle (output x5, cache write x2, read x0.1).
  #               This is what the session cost, NOT what it was worth - no tool
  #               can see the second one, so it is named for what it measures.
  #   production  output as a share of that spend. High means the tokens went
  #               into doing the work; low means they went into paying rent on
  #               a window - re-caching context that was already there.
  #   control     breaches and gap rewrites per cycle. The one axis that is
  #               purely about how the session was driven.
  function grade(v, med, invert,   r) {
    r = (med > 0) ? v / med : 1
    if (invert) r = (r > 0) ? 1 / r : 9
    return (r >= 1.5) ? "A" : (r >= 1.15) ? "B" : (r >= 0.85) ? "C" : (r >= 0.6) ? "D" : "E" }

  # No corpus median for control - the target is zero, so it is graded against
  # the doctrine directly: a clean cycle breaches nothing. Shared by the row
  # cell and the OVERALL line so the two ladders cannot drift apart.
  function ctlgrade(v) {
    return (v <= 0.05) ? "A" : (v <= 0.25) ? "B" : (v <= 0.5) ? "C" : (v <= 0.9) ? "D" : "E" }

  function gcol(g) {
    return (g == "A") ? GRN : (g == "B") ? GRN : (g == "C") ? BLU : (g == "D") ? YEL : RED }

  # Fills g[1..3] with the letters and g[4..6] with the figures behind them, so
  # the table cell and the panel line can never disagree about a session.
  function gvals(i, g,   wtd, ctl, dis) {
    if (cy[i] < 2) return 0
    wtd = ot[i] * 5 + rt[i] * 2 + cx[i] * RPC * 0.1 * cy[i]
    if (wtd <= 0) return 0
    # Spend is graded ABOVE the floor. The ~FLOOR of cache write every session
    # pays before it has done anything is not a choice, and dividing that
    # one-off by a small cycle count is why a young session graded a letter
    # worse than identical work later on: measured across 91 sessions the raw
    # figure ran 254k/cycle at cycle 1 and settled at 168k by cycle 8, purely
    # from the amortisation. Discounted it sits at 135-150k throughout, so the
    # letter now says how the session was DRIVEN rather than how old it is.
    # Production is deliberately NOT rebased - it measured flat (35% at cycle 1,
    # 35% at cycle 8), so there was nothing there to correct.
    dis = wtd - FLOOR * 2000
    if (dis < wtd * 0.15) dis = wtd * 0.15
    g[4] = dis / cy[i] / 1000
    g[5] = ot[i] * 5 * 100 / wtd
    ctl  = (fb[i] + gp[i] * 2) / cy[i]
    g[1] = grade(g[4], p_wpc, 1)
    g[2] = grade(g[5], p_prod, 0)
    g[3] = ctlgrade(ctl)
    return 1 }

  # The table cell: three letters, spend / production / control, in that order.
  function gcell(i,   g) {
    if (GW == 0) return ""
    if (!gvals(i, g)) return rep(" ", GW)
    # Padded by glyph count, like the sparkline: the colour escapes are bytes
    # the terminal never shows, so anything downstream that counts them lands
    # the rest of the row in the wrong column.
    if (al[i] == 0) return sprintf("%s%s%s%s%s", GRY, g[1] g[2] g[3], R, "", rep(" ", GW - 3))
    return sprintf("%s%s%s%s%s%s%s%s", gcol(g[1]), g[1], gcol(g[2]), g[2], gcol(g[3]), g[3], R, rep(" ", GW - 3)) }

  function scorecard(i,   g, wpc, prod, g1, g2, g3, s) {
    if (!gvals(i, g)) return ""
    wpc = g[4]; prod = g[5]; g1 = g[1]; g2 = g[2]; g3 = g[3]
    # Kept short on purpose - this line sits inside a panel 74 columns wide on
    # a default terminal, and it is the only one here carrying three figures.
    s = sprintf("%s%s%s spend %s%.0fk%s%s/cyc (med %.0f)%s  ", gcol(g1), g1, R, B, wpc, R, D, p_wpc, R)
    s = s sprintf("%s%s%s prod %s%.0f%%%s%s (med %.0f)%s  ", gcol(g2), g2, R, B, prod, R, D, p_prod, R)
    s = s sprintf("%s%s%s control %s%db %dgap%s", gcol(g3), g3, R, B, fb[i], gp[i], R)
    return s }

  # cmp: the short-window panel. The three-row header box becomes one row and
  # the two prompt fields go - they are the largest and the least urgent part of
  # it, and what is left (window, spend, cache, state, the advice) is the half
  # you opened the panel to read.
  # The detail region, framed. It used to print bare under the panel, which read
  # as loose text under an instrument rather than as part of one - and with the
  # brief opening on every selection, that is now most of what is on screen.
  #
  # Buffered rather than framed line by line, because several of these lines are
  # WIDER than the panel above (the growth line runs to 85 columns against a
  # 72-column panel), and framing those in place would punch the right border
  # off - the one failure every frame in this file exists to prevent. So the
  # lines are collected, measured, and the box drawn to fit the widest of them.
  # It is never narrower than the panel, so the two edges line up.
  function dput(s) { DB[++DBN] = s; return "" }
  function dsep()  { DB[++DBN] = "\001"; return "" }
  # For the blocks that already carry their own newlines - wrap(), field(),
  # advice(). The trailing empty line each of them ends on is dropped here
  # rather than framed as a blank row.
  # col is applied per line, never wrapped around the block: a reset appended
  # after the final newline arrives as a line of its own and frames as a blank
  # row inside the box - the same trap pltxt() was written to avoid.
  function dputb(block, col,   a, m, j) {
    m = split(block, a, "\n")
    for (j = 1; j <= m; j++) if (a[j] != "") dput((col == "") ? a[j] : col a[j] R)
    return "" }
  function dflush(   j, w, q, cap) {
    if (DBN < 1) return ""
    # Never narrower than the panel, so the two left edges line up, and never
    # wider than the terminal - a line that outgrew even that is cut rather than
    # allowed to take the right border with it.
    cap = cols - 6
    w = W - 2
    for (j = 1; j <= DBN; j++) if (DB[j] != "\001" && dwid(DB[j]) > w) w = dwid(DB[j])
    # A terminal too narrow to hold the widest line gets the lines bare, the way
    # this region printed before it had a frame. Truncating instead would cut
    # figures out of the middle of the answer, and a border drawn around content
    # that does not fit is worse than no border - it breaks on every row.
    if (w > cap) {
      for (j = 1; j <= DBN; j++) if (DB[j] != "\001") print DB[j]
      DBN = 0
      return "" }
    printf "  %s%s%s%s%s\n", D, ptl, rep(dth, w + 2), ptr, R
    for (j = 1; j <= DBN; j++) {
      if (DB[j] == "\001") {
        printf "  %s%s%s%s%s\n", D, pml, rep(dth, w + 2), pmr, R
        continue }
      q = w - dwid(DB[j]); if (q < 0) q = 0
      printf "  %s%s%s %s%s %s%s%s\n", D, dtv, R, DB[j], rep(" ", q), D, dtv, R }
    printf "  %s%s%s%s%s\n", D, pbl, rep(dth, w + 2), pbr, R
    DBN = 0
    return "" }

  # What a selection is worth on its own. Moving the cursor used to open the
  # whole panel, which made navigating expensive - a third of the window went
  # every time you pressed j. Then it opened nothing, which made the cursor a
  # highlight and no more. This is the middle: four lines that answer "what am I
  # looking at and what should I do about it", with d there for the rest.
  #
  # Deliberately NOT a shorter copy of the row. The row already carries context,
  # growth, cache and the verdict; what it has no room for is what the window
  # has cost, how hard it has been worked, and the reasoning behind the verdict.
  # Those are the three this adds, and they are the three you would have opened
  # the panel for.
  function brief(i,   c, s, t, cp, w) {
    w = W - 15
    c = cx[i] / 1000
    printf "\n"
    dput(sprintf("%s%s%s  %s%s  %s  %s  %s%s", B, nk[i], R, D, vv, pj[i], vv, \
      (al[i] == 0) ? "closed" : (lf[i] > 0) ? sprintf("%dm cache", lf[i]) : "cold", R))
    dsep()
    s = sprintf("  %s%d cycle%s%s", D, cy[i], (cy[i] == 1 ? "" : "s"), R)
    if (cy[i] > 0)
      s = s sprintf("  %s%s%s  %s%.1fk out/cycle%s", D, vv, R, D, ot[i] / cy[i] / 1000, R)
    if (cparts(i, cp))
      s = s sprintf("  %s%s%s  %s%s%s %sweighted  ~$%.2f%s", D, vv, R, B, hum(cp[0]), R, D, usd(cp[0]), R)
    if (pk[i]) s = s sprintf("  %s%s%s  %sparked %s ago%s%s", D, vv, R, \
      (pstale(i) ? YEL : BLU), ago(ck[i]), \
      (pstale(i) ? sprintf(", %s behind", pbehind(i)) : ""), R)
    if (rn[i]) s = s sprintf("  %s%s%s  %s%s working%s", D, vv, R, B CYN, (watch ? spin() : here), R)
    dput(s)
    t = tip(i, 1)
    if (t != "") dputb(advice(urgency(i), t, w))
    dput(sprintf("  %sd%s  %sthe full panel%s", B, R, D, R))
    dflush() }

  function detail(i, cmp,   c, w, hdr, t, cp, gs) {
    w = W - 15
    printf "\n"
    # The header is a row of the same box now, closed off by a divider, rather
    # than a second box stacked on the first with a blank line between. Same
    # shape as the brief, one weight below the panel, so expanding a selection
    # reads as the same object growing rather than a different one opening.
    dput(sprintf("%s%s%s  %s%s %s  %s %s%s", B, nk[i], R, D, vv, nm[i], vv, pj[i], R))
    dsep()
    if (!cmp) {
      dputb(field("opened", ti[i], w))
      if (lp[i] != "" && lp[i] != ti[i]) dputb(field("latest", lp[i], w))
      dsep() }
    dput(sprintf("    %s%s%s%s   %spid %s%s", GRY, pad("session", 9), R, uuid[i], D, pid[i], R))
    # Which name you are looking at, and that it is only the name this tool gives
    # the session - the CLI name is the one beside it in the panel header, and
    # nothing here rewrites it.
    if (watch)
      dput(sprintf("    %s%s%s%s%s%s   %s%s%s", GRY, pad("name", 9), R, \
        ((nv[i] || nc[i] != "") ? CYN : ""), nk[i], R, D, \
        (nc[i] != "" ? sprintf("typed with /n %s n clears it", vv) \
         : nv[i] ? sprintf("re-roll %d/%d %s n cycles, %d back to the default", \
                         nv[i], nvar - 1, vv, nvar - nv[i]) \
               : sprintf("from its first prompt %s n re-rolls it, /n NAME names it", vv)), R))
    # What the fail-safe is doing to this window, in the one place with room to
    # say why. The miss line is the important one: it means the ping landed on a
    # different prefix and REBUILT the window rather than reading it, so holding
    # this session is not something the tool can do from here.
    c = cx[i] / 1000
    t = sprintf("    %s%s%s%.1fk  %s%s%s  %d cycle%s  %s%s%s  %.1fk output", GRY, pad("window", 9), R, c, D, vv, R, cy[i], (cy[i] == 1 ? "" : "s"), D, vv, R, ot[i] / 1000)
    if (cy[i] > 0) t = t sprintf(" %s(%.1fk per cycle, %.1fk last)%s", D, ot[i] / cy[i] / 1000, ol[i] / 1000, R)
    dput(t)
    if (cparts(i, cp)) {
      dput(sprintf("    %s%s%s%s%s%s weighted  %s~$%.2f at $%d/MTok in", \
        GRY, pad("spend", 9), R, B, hum(cp[0]), R, D, usd(cp[0]), price))
      # The percentages alone could not be turned back into money, which is the
      # question the panel is open for - so each share now carries its own
      # figure next to the split bar rather than only its fraction of it.
      dput(sprintf("    %s%s   %sout%s %s %s%.0f%%%s  %swrite%s %s %s%.0f%%%s  %sread%s %s %s%.0f%%%s", \
        rep(" ", 9), splitbar(cp[1], cp[2], cp[3], 14), \
        GRN, R, padl(hum(cp[1]), 5), D, cp[1] * 100 / cp[0], R, \
        ORG, R, padl(hum(cp[2]), 5), D, cp[2] * 100 / cp[0], R, \
        BLU, R, padl(hum(cp[3]), 5), D, cp[3] * 100 / cp[0], R)) }
    # The panel carried output but never growth, which is the wrong half to
    # leave out: output is a verdict on a cycle already paid for, growth is the
    # one number here you can still act on while the session is running.
    if (gstats(i, gs))
      dput(sprintf("    %s%s%s%s%.1fk%s %smed%s   %.1fk %slast%s   %s%.1fk%s %speak%s   %sagainst a %.0fk budget, %d cycle%s over%s", \
        GRY, pad("growth", 9), R, B, gs[1] / 1000, R, D, R, gs[3] / 1000, D, R, \
        (gs[2] > gbud ? RED : ""), gs[2] / 1000, R, D, R, \
        D, gbud / 1000, gs[4], (gs[4] == 1 ? "" : "s"), R))
    t = scorecard(i)
    if (t != "") dput(sprintf("    %s%s%s%s", GRY, pad("graded", 9), R, t))
    if (al[i] == 0)
      dput(sprintf("    %s%s%s%sclosed%s  %s%s%s  idle %dm", GRY, pad("cache", 9), R, GRY, R, D, vv, R, id[i]))
    else if (lf[i] > 0)
      dput(sprintf("    %s%s%s%s%dm of %dm left%s  %s%s%s  idle %dm", GRY, pad("cache", 9), R, GRN, lf[i], ttl, R, D, vv, R, id[i]))
    else
      dput(sprintf("    %s%s%s%sCOLD for %dm%s  %s%s%s  a full rewrite is already due", GRY, pad("cache", 9), R, RED, -lf[i], R, D, vv, R))
    t = sprintf("    %s%s%s", GRY, pad("state", 9), R)
    if (al[i] == 0)      t = t sprintf("%sclosed%s", GRY, R)
    else if (rn[i])      t = t sprintf("%sa turn is running%s", B CYN, R)
    else                 t = t sprintf("%swaiting for you%s", GRN, R)
    if (pk[i]) t = t sprintf("  %s%s%s  %sparked%s %s%s, %s ago%s%s", D, vv, R, \
      (pstale(i) ? YEL : BLU), R, D, ckt[i], ago(ck[i]), \
      (pstale(i) ? sprintf("%s - %s of work since, so it resumes an older state", YEL, pbehind(i)) : ""), R)
    dput(t)
    # Wrapped, not one long line: with several topics on a busy project this
    # runs well past the panel and would be the only thing here that does.
    if (cko[i] != "")
      dputb(wrap("also parked here: " cko[i], w, "    " rep(" ", 9)), D)
    dsep()
    dputb(advice(urgency(i), tip(i, 1), w))
    t = tip(i, 2)
    if (t != "") dputb(advice(D, t, w))
    # The one state where "live process, dead cache" is correct and still looks
    # like a bug, so it gets said out loud rather than left to be re-derived.
    if (tc[i] > 0 && al[i] == 1)
      dputb(advice(BLU, sprintf("the transcript was touched %s after its last real turn - reopened, not spoken to. The cache clock runs from the turn, not the touch, so this window is older than the file looks.", ago(tc[i])), w))
    if (nlive() > 2)
      dputb(advice(YEL, sprintf("%d sessions are live at once. 59%% of measured gap-rewrites had another of your own running - the second terminal is what starves the first.", nlive()), w))
    dflush() }

  # How loudly a row wants attention: the colour of its first tip, of its
  # context bar, and the test for whether the overview lists it at all.
  #
  # The ladder is deliberately NOT "big window = bad". A large window whose
  # cache keeps hitting costs 0.1x a request and is fine; what costs is a gap,
  # and what a gap costs scales with the window. So:
  #   warm   green, until a cut would actually pay - CUT_PK with a checkpoint
  #          on disk, CUT_NO without - and orange only when it is about to lapse
  #          with enough in it to be worth parking. Never red: nothing has been
  #          spent yet and there is no deadline.
  #   cold   the rewrite is already booked for the next message, so this is
  #          where red lives: red above CLEAR_NO (clear before typing), orange
  #          from CLEAR_PK (clear if it is parked), yellow below - a gap
  #          happened, but under the floor clearing only makes the window bigger,
  #          so there is nothing to do about it.
  # Split into a rank and a colour so the verdict glyph and the advice colour
  # are two renderings of ONE decision rather than two ladders that can drift.
  #   3 act now (cold, above the clear bar)   2 act soon (park it / clear it)
  #   1 a cut would pay if you want it        0 nothing to decide
  function urank(i,   c) {
    if (al[i] != 1) return -1
    c = cx[i] / 1000
    if (lf[i] > 0) {
      if (lf[i] <= 10 && c >= PARK_AT) return 2
      # Warm and overheating is the case this ladder had no rung for: the cache
      # is doing its job, nothing is about to lapse, and the window is still
      # costing more per cycle than it returns. That is a decision, so it ranks
      # as one rather than sitting green until the cut bar 60k further up.
      if (c >= CUT_NO || (pk[i] && c >= CUT_PK)) return 1
      if (c >= OVERHEAT && hot(i) >= 1) return 1
      return 0 }
    if (c >= CLEAR_NO) return 3
    # CLEAR_PK is the bar for a window with a checkpoint on disk; without one it
    # is CLEAR_NO, which is 30k further up. Ignoring that made an unparked
    # window between the two look like it wanted clearing when tip() was, on the
    # same row, telling it to carry on.
    if (pk[i] && c >= CLEAR_PK) return 2
    return 1 }

  function urgency(i,   u) {
    u = urank(i)
    return (u < 0) ? GRY : (u == 3) ? RED : (u == 2) ? ORG : (u == 1) ? YEL : GRN }

  # The verdict, as one glyph. Filled triangle: do something now. Hollow:
  # cutting would pay, when you feel like it. Ring: nothing to decide, which is
  # most rows most of the time and is drawn dim so it recedes.
  function actg(i,   u) {
    u = urank(i)
    if (u < 0)  return GRY g_ok R
    if (u >= 2) return urgency(i) g_act R
    if (u == 1) return YEL g_cut R
    return D GRN g_ok R }

  function nlive(   i, c) { for (i = 1; i <= n; i++) if (al[i] == 1) c++; return c }

  function ago(m) {
    if (m < 60)   return sprintf("%dm", m)
    if (m < 2880) return sprintf("%dh", int(m / 60))
    return sprintf("%dd", int(m / 1440)) }

  # Overview mode keeps the one-line-per-problem list; the detail panel replaces
  # it once a row is selected. Only rows with something to do get a line.
  function push(i,   col, c, t, pw, s) {
    if (al[i] != 1) return
    c = cx[i] / 1000
    # Only rows with something to DO are listed, so a warm window that is merely
    # large stays out of it - its colour in the table says enough.
    if (lf[i] > 0 && !(lf[i] <= 10 && c >= PARK_AT)) return
    col = urgency(i)
    t = tip(i, 1); if (t == "") return
    # 10 = "   " + arrow + " " + "  " + vv + "  ", all one column each.
    pw = length(nk[i]) + 8
    s = wrap(t, W - 4 - pw, rep(" ", pw))
    acts = acts sprintf("%s%s%s %s%s%s  %s%s%s  %s", col, arrow, R, B, nk[i], R, D, vv, R, substr(s, pw + 1)) }
  ' "$snap"
}

# The history tab. Everything the sessions view says about ONE window, asked of
# the whole record instead: where the money went, what a typical cycle costs,
# and - the only part that answers whether any of this is getting better - the
# last seven days measured against the stretch before them.
#
# Reads nothing but token-history.csv and the title cache, so it costs one awk.
# It is redrawn every frame in watch mode for the same reason render is: a frame
# that re-reads cheap data beats a frame that has to know when its data expired.
# Draws a thin frame around every block of a stream, a block being whatever sits
# between two blank lines.
#
# Why a filter and not a hundred edits. The analytics view is built from about a
# hundred printfs whose formats carry their own newlines and line continuations;
# rewriting each into a framed call would have been a hundred chances to lose a
# column, for no gain that the reader can see. Framing the finished text instead
# costs one awk, cannot desynchronise from what it frames, and treats the blank
# lines that were already the section separators as exactly what they are.
#
# Anything already framed passes through untouched, so the title box and any
# block that draws its own border are not double-boxed.
frame_blocks() {
  awk -v W="$1" -v ROWS="$2" -v PAGE="${3:-1}" -v PGFILE="${4:-}" -v D="$C_DIM" -v R="$C_R" \
      -v ptl="$G_PTL" -v ptr="$G_PTR" -v pbl="$G_PBL" -v pbr="$G_PBR" \
      -v ph="$G_PH" -v pv="$G_PV" -v pml="$G_PML" -v pmr="$G_PMR" '
    function rep(s, n,   i, o) { for (i = 0; i < n; i++) o = o s; return o }
    # Display columns: strip the colour escapes, then the UTF-8 continuation
    # bytes, and what is left is one byte per single-width character. Depends on
    # the C locale, which the script pins - see the note at the top of the file.
    function dwid(s,   t) {
      t = s
      gsub(/\033\[[0-9;]*m/, "", t)
      gsub(/[\200-\277]/, "", t)
      return length(t) }
    # Cut to n display columns without slicing a colour escape or a multi-byte
    # glyph in half. substr() alone cannot: it counts bytes, so it would leave
    # half a block glyph and a dangling colour on the line.
    function dcut(s, n,   i, c, o, w, L) {
      L = length(s); i = 1; w = 0
      while (i <= L) {
        c = substr(s, i, 1)
        if (c == "\033") {
          while (i <= L && substr(s, i, 1) !~ /[a-zA-Z]/) { o = o substr(s, i, 1); i++ }
          if (i <= L) { o = o substr(s, i, 1); i++ }
          continue }
        if (w >= n) break
        o = o c; i++
        if (c ~ /[\300-\377]/)
          while (i <= L && substr(s, i, 1) ~ /[\200-\277]/) { o = o substr(s, i, 1); i++ }
        w++ }
      return o }
    function emit(t,   q) {
      sub(/^  /, "", t)
      # Nothing leaves here wider than the frame. A line that would push the
      # right border off the panel is cut instead - the border is load-bearing,
      # the tail of a sentence is not.
      if (dwid(t) > W - 2) t = dcut(t, W - 3) "~" R
      q = W - 2 - dwid(t); if (q < 0) q = 0
      printf "  %s%s%s %s%s %s%s%s\n", D, pv, R, t, rep(" ", q), D, pv, R }
    # The block name, taken from the label column the analytics view already
    # prints - so the shedding order below can be written in the same words the
    # screen uses, and a block with no label inherits the one above it.
    function nameof(t,   u) {
      u = t
      gsub(/\033\[[0-9;]*m/, "", u)
      sub(/^  */, "", u)
      if (u !~ /^[A-Z]/) return ""
      sub(/  .*$/, "", u)
      return u }
    { if ($0 ~ /^[ \t]*$/) { close_block(); next }
      # A line that already draws a frame of its own marks the whole block as
      # pre-framed - the title box being the one that matters.
      if (nb == 0 && $0 ~ /[\xe2][\x94\x95]/) framed = 1
      buf[++nb] = $0 }
    function close_block(   i, nm) {
      if (nb == 0) return
      NBL++
      BF[NBL] = framed; BN[NBL] = nb
      nm = ""
      for (i = 1; i <= nb; i++) { BL[NBL, i] = buf[i]; if (nm == "") nm = nameof(buf[i]) }
      BM[NBL] = (nm != "") ? nm : LASTNM
      if (nm != "") LASTNM = nm
      nb = 0; framed = 0 }
    END {
      close_block()
      # Pages, not losses. The tab redraws in place and cannot scroll, so this
      # used to compute eleven sections, throw eight of them on the floor and
      # advise a taller window - which is the tool declining to show you what it
      # had already worked out. The blocks now run over as many pages as they
      # need and [ ] walks them, so nothing is computed and discarded.
      #
      # Counted exactly, because guessing high here costs a whole section. Every
      # block spends its own lines plus one: a framed one the blank after it, a
      # chained one the rule above it. The framed title is reprinted on every
      # page, so its height is the base each page starts from; then one closing
      # rule and one pager line.
      base = 1
      for (i = 1; i <= NBL; i++) if (BF[i]) base += BN[i] + 1
      cap = ROWS - 2
      if (cap < base + 3) cap = base + 3
      pg = 1; used = base
      for (i = 1; i <= NBL; i++) {
        if (BF[i]) continue
        h = BN[i] + 1
        if (used + h > cap && used > base) { pg++; used = base }
        PG[i] = pg; used += h }
      NPG = pg
      P = PAGE + 0; if (P < 1) P = 1; if (P > NPG) P = NPG
      # The shell cannot know how many pages there were until this has run, so
      # it is told - otherwise pressing ] past the end walks a counter nothing
      # can see and [ spends the same number of presses walking back.
      if (PGFILE != "") { printf "%d %d\n", P, NPG > PGFILE; close(PGFILE) }
      for (i = 1; i <= NBL; i++) {
        if (!BF[i] && PG[i] != P) continue
        if (BF[i]) {
          if (open) { printf "  %s%s%s%s%s\n", D, pbl, rep(ph, W), pbr, R; open = 0 }
          for (j = 1; j <= BN[i]; j++) print BL[i, j]
          print ""
          continue }
        # A chained block opens with a divider rather than a bottom rule, a
        # blank line and a top rule: three lines become one, and the tab reads
        # as one instrument with divisions instead of eleven stacked boxes.
        if (!open) { printf "  %s%s%s%s%s\n", D, ptl, rep(ph, W), ptr, R; open = 1 }
        else       { printf "  %s%s%s%s%s\n", D, pml, rep(ph, W), pmr, R }
        for (j = 1; j <= BN[i]; j++) emit(BL[i, j]) }
      if (NPG > 1 && open) {
        nxt = ""
        for (i = 1; i <= NBL; i++) if (!BF[i] && PG[i] == P + 1 && nxt == "") nxt = tolower(BM[i])
        printf "  %s%s%s%s%s\n", D, pml, rep(ph, W), pmr, R
        emit(sprintf("%spage %d of %d   %s   %s[ ]%s or PgUp/PgDn%s%s", \
          D, P, NPG, pv, R, D, (nxt != "") ? "   next: " nxt : "", R)) }
      if (open) printf "  %s%s%s%s%s\n", D, pbl, rep(ph, W), pbr, R }'
}

analytics() {
  local CLOCK AW
  CLOCK=$(date "+%H:%M:%S")
  # Refreshes the cache if it has gone stale; the awk below reads the file, not
  # this output, so that a missing map degrades to "(unknown)" rows rather than
  # to a broken pipe.
  proj_rows >/dev/null 2>&1
  # The same width the awk below derives, computed once here so the frame and
  # the thing it frames cannot disagree about where the right edge is.
  AW=${COLS:-92}
  [ "$AW" -lt 76 ] && AW=76
  [ "$AW" -gt 160 ] && AW=160
  AW=$((AW - 6))
  [ "$AW" -gt 104 ] && AW=104
  awk -F, -v now="${EPOCHSECONDS:-$(date +%s)}" -v cols="${COLS:-92}" -v rpc="$RPC" \
      -v price="$PRICE_IN" -v obud="$OBUD" -v gbud="$GBUD" -v watch="$WATCH" \
      -v plan5="$PLAN_5H" -v planwk="$PLAN_WK" -v titles="$TITLES" \
      -v projmap="$PROJMAP" \
      -v p_wpc="$M_WPC" -v p_prod="$M_PROD" -v wk="$BUCKET" -v hud="$HUD" \
      -v floor="$M_FLOOR" -v heatbar="$M_HEAT" -v m_rem="$M_REM" \
      -v full="$G_FULL" -v empt="$G_EMPT" -v sparks="$SPARKS" -v arrow="$G_ARROW" \
      -v gtl="$G_TL" -v gtr="$G_TR" -v gbl="$G_BL" -v gbr="$G_BR" -v ghh="$G_H" \
      -v vv="$G_V" -v vf="$G_VF" -v up="$G_UP" -v dn="$G_DN" -v clock="$CLOCK" \
      -v R="$C_R" -v D="$C_DIM" -v B="$C_B" -v GRN="$C_GRN" -v YEL="$C_YEL" \
      -v ORG="$C_ORG" -v RED="$C_RED" -v BLU="$C_BLU" -v GRY="$C_GRY" '
  function rep(s, n,   i, o) { for (i = 0; i < n; i++) o = o s; return o }
  # Letter-spaced, for the panel titles only. A readout names itself with
  # room around its letters; a paragraph does not. length() stays honest
  # because the spacing is really in the string rather than faked with a
  # terminal attribute - box() measures what it is given.
  function spaced(s,   i, o) {
    for (i = 1; i <= length(s); i++) o = o (i > 1 ? " " : "") substr(s, i, 1)
    return o }
  function hd(s) { return hud ? toupper(s) : s }
  function ttlz(s) { return hud ? spaced(s) : s }
  function pad(s, n,   l) { l = length(s); return (l >= n) ? substr(s, 1, n) : s rep(" ", n - l) }
  function ell(s, n) { return (length(s) > n) ? substr(s, 1, n - 1) "~" : s }
  function lab(t) { return "  " GRY pad(hd(t), LB) R }
  function hum(v) {
    if (v >= 1000000) return sprintf("%.1fM", v / 1000000)
    if (v >= 1000)    return sprintf("%.0fk", v / 1000)
    return sprintf("%d", v) }
  function usd(w) { return w * price / 1000000 }
  function ep(t,   s) { s = t; gsub(/[-:]/, " ", s); return mktime(s " 00") }
  # Same three as the sessions view, and for the same reason: nothing on screen
  # should be floating outside a frame. See dwid() there for why the width is
  # measured rather than declared.
  function dwid(s,   t) {
    t = s
    gsub(/\033\[[0-9;]*m/, "", t)
    gsub(/[\200-\277]/, "", t)
    return length(t) }
  function box(text,   s, q) {
    q = W - 2 - dwid(text); if (q < 0) q = 0
    s = sprintf("  %s%s%s%s%s\n", D, gtl, rep(ghh, W), gtr, R)
    s = s sprintf("  %s%s%s %s%s %s%s%s\n", D, vf, R, text, rep(" ", q), D, vf, R)
    return s sprintf("  %s%s%s%s%s\n", D, gbl, rep(ghh, W), gbr, R) }
  function sortv(v, m,   i, j, t) {
    for (i = 2; i <= m; i++) {
      t = v[i]; for (j = i - 1; j >= 1 && v[j] > t; j--) v[j + 1] = v[j]; v[j + 1] = t } }
  function pctl(v, m, p,   ix) {
    if (m < 1) return 0
    ix = int(p * m + 0.5); if (ix < 1) ix = 1; if (ix > m) ix = m
    return v[ix] }
  # Three shares of one bar, in the same colours the cost column uses.
  function splitbar(a, b, c, wd,   t, na, nb, nc) {
    t = a + b + c; if (t <= 0) return rep(empt, wd)
    # A one-cell bar cannot show a split, and rounding three shares into a
    # single cell hands it to whichever colour is drawn last - so a project
    # that is two thirds cache writes would come out blue. The projects block
    # scales its bar to the share of total spend, so its smallest lines really
    # do come out one cell wide. One cell says one thing: the largest share.
    if (wd <= 1)
      return ((a >= b && a >= c) ? GRN : (b >= c) ? ORG : BLU) rep(full, wd) R
    na = int(a / t * wd + 0.5); nb = int(b / t * wd + 0.5)
    if (na + nb > wd) nb = wd - na
    if (nb < 0) nb = 0
    nc = wd - na - nb
    return GRN rep(full, na) ORG rep(full, nb) BLU rep(full, nc) R }
  # Movement between two periods. Which direction counts as good is not readable
  # off the number - spend falling is good, output share rising is - so the
  # caller says which, and the colour follows from that rather than from a sign.
  function delta(a, b, low,   p) {
    if (a <= 0) return ""
    p = (b - a) * 100 / a
    if (p > -1 && p < 1) return sprintf("%s- flat%s", D, R)
    return sprintf("%s%s%.0f%%%s", ((low ? (p < 0) : (p > 0)) ? GRN : RED), \
      (p < 0 ? dn : up), (p < 0 ? -p : p), R) }
  function grade(v, med, invert,   r) {
    r = (med > 0) ? v / med : 1
    if (invert) r = (r > 0) ? 1 / r : 9
    return (r >= 1.5) ? "A" : (r >= 1.15) ? "B" : (r >= 0.85) ? "C" : (r >= 0.6) ? "D" : "E" }
  function ctlgrade(v) {
    return (v <= 0.05) ? "A" : (v <= 0.25) ? "B" : (v <= 0.5) ? "C" : (v <= 0.9) ? "D" : "E" }
  function gcol(g) {
    return (g == "A") ? GRN : (g == "B") ? GRN : (g == "C") ? BLU : (g == "D") ? YEL : RED }
  # One graded series across the buckets: a sparkline of the magnitude, and the
  # letter each bucket earned directly underneath it. Two columns per bucket in
  # both rows, so a letter is always under its own glyph. The glyph is coloured
  # by the letter, which is the pairing that makes the block readable at a
  # glance: a tall bar is only bad if it is orange.
  function gser(name, kind, v,   i, mx, ix, sp, ls, g, g0, GB) {
    mx = 0
    for (i = 0; i < SPAN; i++) {
      GB[i] = -1
      if (bkn[i] < 1) continue
      if      (kind == 1) v = dg[i] / bkn[i] / 1000            # weighted per cycle, above the floor
      else if (kind == 2) v = (dw[i] > 0) ? bko[i] * 100 / dw[i] : 0
      else                v = bkc[i] / bkn[i]                   # breaches + rewrites
      GB[i] = v
      if (v > mx) mx = v }
    sp = ""; ls = ""
    for (i = SPAN - 1; i >= 0; i--) {
      v = GB[i]
      if (v < 0) { sp = sp GRY SP[1] R " "; ls = ls D "." R " "; continue }
      g = (bkn[i] < 2) ? "-" \
        : (kind == 1) ? grade(v, p_wpc, 1) \
        : (kind == 2) ? grade(v, p_prod, 0) : ctlgrade(v)
      ix = (mx > 0) ? int(v / mx * 7) + 1 : 1
      if (ix > 8) ix = 8
      if (ix < 1) ix = 1
      sp = sp ((g == "-") ? GRY : gcol(g)) SP[ix] R " "
      ls = ls ((g == "-") ? D : gcol(g)) g R " "
      if (i == 0) g0 = g }
    printf "%s%s%s%s", lab(""), pad(name, SUBW), sp, R
    if (g0 != "" && g0 != "-") printf "  %s%s%s %s%s%s", gcol(g0), g0, R, D, (wk ? "this week" : "today"), R
    printf "\n%s%s%s\n", lab(""), rep(" ", SUBW), ls }

  BEGIN {
    split(sparks, SP, " ")
    LB = 12
    NB = wk ? 12 : 14                    # a fortnight of days, or a quarter of weeks
    BUNIT = wk ? "weeks" : "days"
    SUBW = 12                            # the sub-label column inside the grades block
    if (cols + 0 < 76) cols = 76
    if (cols + 0 > 160) cols = 160
    W = cols - 6; if (W > 104) W = 104
    TXW = W - LB - 4
    while ((getline tline < titles) > 0) {
      tp = index(tline, "\t"); if (!tp) continue
      TT[substr(tline, 1, 8)] = substr(tline, tp + 1) }
    close(titles)
    while ((getline pline < projmap) > 0) {
      tp = index(pline, "\t"); if (!tp) continue
      PJ[substr(pline, 1, tp - 1)] = substr(pline, tp + 1) }
    close(projmap) }

  NR > 1 && $2 != "" {
    e = ep($1); if (e <= 0) next
    # Same growth/churn split the sessions view uses, and for the same reason:
    # growth is the half a prompt chose, churn is the window being rewritten.
    g = (($2 in pv) ? $6 - pv[$2] : 0); if (g < 0) g = 0
    ch = $5 - g; if (ch < 0) ch = 0
    pv[$2] = $6
    w = $4 * 5 + $5 * 2 + $6 * rpc * 0.1
    # Two weights, deliberately. w is what the cycle actually cost and is what
    # every total and every dollar figure below is built from. wg is the same
    # number with the cold floor taken off cycle 1, and it is what the GRADES
    # use - the floor is not a choice, and amortising it over a young session
    # was worth a whole letter. See the note in measure_constants.
    wg = w
    if ($3 + 0 == 1 && floor > 0) { wg = w - floor * 2000; if (wg < w * 0.15) wg = w * 0.15 }
    bch = ($7 != "-" && $7 != "") ? 1 : 0
    grw = ($3 + 0 > 1 && ch > 60000) ? 1 : 0
    N++
    TW += w; TO += $4 * 5; TWR += $5 * 2; TRD += $6 * rpc * 0.1
    WV[N] = w; OV[N] = $4; GV[N] = g
    # A running top-8 by weighted cost, kept here rather than sorted at the end
    # so the whole history never has to be held twice. Only 5 are printed; the
    # spare three absorb ties without the list going short.
    if (w > cw[8]) {
      cw[8] = w; ct[8] = $1; cs[8] = $2; co[8] = $4; cg[8] = g; cb[8] = $6
      for (q = 8; q > 1 && cw[q] > cw[q - 1]; q--) {
        z = cw[q]; cw[q] = cw[q-1]; cw[q-1] = z; z = ct[q]; ct[q] = ct[q-1]; ct[q-1] = z
        z = cs[q]; cs[q] = cs[q-1]; cs[q-1] = z; z = co[q]; co[q] = co[q-1]; co[q-1] = z
        z = cg[q]; cg[q] = cg[q-1]; cg[q-1] = z; z = cb[q]; cb[q] = cb[q-1]; cb[q-1] = z } }
    if ($4 > obud) OB++
    if (g > gbud) GB++
    NBR += bch; NGR += grw
    # What a gap rewrite actually cost is the churn it paid at the write rate,
    # not the whole cycle it happened to land on.
    if (grw) GRW += ch * 2
    if ($3 + 0 == 1) NS++
    sw[$2] += w; sn[$2]++; so[$2] += $4 * 5
    # Output by position within its session, in fifths. Needs a second pass to
    # know how long each session turned out to be, so the rows are held and the
    # banding happens in END.
    PS[N] = $2; PO[N] = $4; PC[N] = $3 + 0
    if (grw) GRS[$2]++
    # Hoisted above its old home a few lines down: the per-project block wants
    # it too, and two assignments that must agree is one more than there needs
    # to be.
    age = now - e
    # Per project. A transcript whose directory has since been deleted still has
    # rows in the history, so those land in one honest bucket rather than being
    # dropped - a project panel that quietly loses 5% of the spend is worse than
    # one that admits it cannot place it.
    pj = ($2 in PJ) ? PJ[$2] : "(unplaced)"
    PJW[pj] += w; PJN[pj]++; PJO[pj] += $4 * 5; PJR[pj] += $5 * 2
    PJD[pj] += $6 * rpc * 0.1
    if (!(($2 SUBSEP pj) in PJSEEN)) { PJSEEN[$2 SUBSEP pj] = 1; PJS[pj]++ }
    if (age <= 604800) PJ7[pj] += w
    dk = substr($1, 1, 10); if (!(dk in dayseen)) { dayseen[dk] = 1; NDAYS++ }
    # One bucket per day or per week, and every series below is drawn from these
    # rather than from its own pass - so the spend sparkline, the three grade
    # rows and the letters under them can never disagree about which day is
    # which.
    di = int(age / (wk ? 604800 : 86400))
    if (di < NB) { dw[di] += w; dg[di] += wg; bko[di] += $4 * 5; bkn[di]++; bkc[di] += bch + 2 * grw }
    if      (age <= 604800)  { A7 += w; A7G += wg; A7O += $4 * 5; A7N++; A7C += bch + 2 * grw }
    else if (age <= 1209600) { B7 += w; B7G += wg; B7O += $4 * 5; B7N++; B7C += bch + 2 * grw }
    else                     { C7 += w; C7G += wg; C7O += $4 * 5; C7N++; C7C += bch + 2 * grw }
    if (age <= 86400) TDAY += w
    if (age <= 18000) T5H += w }

  END {
    AT = ttlz("ANALYTICS")
    hv = sprintf("%s   %d cycles | %d sessions | %d days", AT, N, NS, NDAYS)
    hb = sprintf("%s%s%s   %s%d cycles %s %d sessions %s %d days%s", \
      B, AT, R, D, N, vv, NS, vv, NDAYS, R)
    hgap = W - 2 - length(hv) - length(clock); if (hgap < 1) hgap = 1
    printf "\n%s\n", box(hb rep(" ", hgap) D clock R, length(hv) + hgap + length(clock))
    if (N == 0) { printf "  %sno history yet - the Stop hook writes one row per cycle%s\n\n", D, R; exit }

    printf "%s%s%s weighted%s   %s~$%.0f at $%d/MTok in, output x5 write x2 read x0.1%s\n", \
      lab("spend"), B, hum(TW), R, D, usd(TW), price, R
    printf "%s%s   %s%s%s %.0f%% output   %s%s%s %.0f%% cache writes   %s%s%s %.0f%% cache reads\n\n", \
      lab(""), splitbar(TO, TWR, TRD, 16), \
      GRN, full, R, TO * 100 / TW, ORG, full, R, TWR * 100 / TW, \
      BLU, full, R, TRD * 100 / TW

    sortv(WV, N); sortv(OV, N); sortv(GV, N)
    printf "%s%sweighted%s  med %s   p90 %s\n", lab("per cycle"), D, R, \
      hum(pctl(WV, N, 0.5)), hum(pctl(WV, N, 0.9))
    printf "%s%soutput%s    med %s   p90 %s   %s%.0f%% of cycles over the %.0fk budget%s\n", \
      lab(""), D, R, hum(pctl(OV, N, 0.5)), hum(pctl(OV, N, 0.9)), \
      (OB * 100 / N >= 20 ? YEL : D), OB * 100 / N, obud / 1000, R
    printf "%s%sgrowth%s    med %s   p90 %s   %s%.0f%% of cycles over the %.0fk budget%s\n\n", \
      lab(""), D, R, hum(pctl(GV, N, 0.5)), hum(pctl(GV, N, 0.9)), \
      (GB * 100 / N >= 20 ? YEL : D), GB * 100 / N, gbud / 1000, R

    # Concentration, not average - and it is the line that decides what the fix
    # even IS. The doctrine claims a breach is one prompt that bundled three
    # tasks rather than a slow drift upward; if it is right, a tenth of the
    # cycles carry a wildly disproportionate share and the lever is SPLITTING
    # prompts. If the shares came out near 10% the drift reading would be the
    # correct one and the lever would be trimming every cycle instead. An
    # average can never tell those two apart, which is why it needed its own
    # line rather than another percentile on the ones above.
    k10 = int(N * 0.1 + 0.5); if (k10 < 1) k10 = 1
    for (i = 1; i <= N; i++) { ao_ += OV[i]; ag_ += GV[i] }
    for (i = N - k10 + 1; i <= N; i++) { to_ += OV[i]; tg_ += GV[i] }
    po = (ao_ > 0) ? to_ * 100 / ao_ : 0
    pg = (ag_ > 0) ? tg_ * 100 / ag_ : 0
    printf "%s%sthe dearest %d%% of cycles carry%s   %s%.0f%%%s %sof all output%s   %s%.0f%%%s %sof all growth%s\n", \
      lab("shape"), D, int(k10 * 100 / N + 0.5), R, \
      (po >= 25 ? YEL : B), po, R, D, R, (pg >= 25 ? YEL : B), pg, R, D, R
    printf "%s%s%s%s\n\n", lab(""), D, \
      ((po >= 25 || pg >= 25) \
        ? "concentrated, so the lever is splitting the prompts that bundle three tasks" \
        : "spread evenly, so this is drift rather than a handful of bad prompts"), R

    # Trim the empty buckets off the old end. Twelve weeks of axis under three
    # weeks of history is nine columns of nothing, and it makes the history look
    # like a collapse rather than like a tool that has only been running a
    # fortnight. Every series below draws the same SPAN, so they stay aligned.
    SPAN = 1
    for (i = 0; i < NB; i++) if (bkn[i] > 0) SPAN = i + 1
    mx = 0
    for (i = 0; i < SPAN; i++) if (dw[i] > mx) mx = dw[i]
    sp = ""
    for (i = SPAN - 1; i >= 0; i--) {
      ix = (mx > 0 && dw[i] > 0) ? int(dw[i] / mx * 7) + 1 : 1
      if (ix > 8) ix = 8
      sp = sp ((dw[i] > 0) ? BLU : GRY) SP[ix] }
    printf "%s%s%s   %s%d %s, total%s   today %s%s%s   7d %s%s%s   5h %s%s%s\n\n", \
      lab(wk ? "weekly" : "daily"), sp, R, D, SPAN, BUNIT, R, \
      B, hum(TDAY), R, B, hum(A7), R, B, hum(T5H), R

    # The same three axes the sessions tab grades one row on, per bucket, over
    # the whole history: height is the magnitude, the letter under each glyph is
    # what that bucket GRADED. Both are needed and neither substitutes for the
    # other - a week can spend less and still grade worse, because the letter is
    # relative to the median for this machine and the bar is not.
    #
    # Two columns per bucket, for both rows, so a letter always sits under its
    # own glyph. Anything measured on fewer than two cycles is not graded at
    # all: one cycle is not a week, and an A that means "you worked once" is
    # worse than no letter.
    printf "%s%sheight is the amount, the letter under it is the grade%s\n", \
      lab("grades"), D, R
    gser("spend", 1); gser("production", 2); gser("control", 3)
    leg = sprintf("%sA%s %sB%s %sC%s %sD%s %sE%s  %s- under 2 cycles  . none%s", \
      GRN, R, GRN, R, BLU, R, YEL, R, RED, R, D, R)
    hint = watch ? "w  " (wk ? "days" : "weeks") : "--" (wk ? "daily" : "weekly")
    printf "%s%s%s   %s%s%s\n\n", lab(""), rep(" ", SUBW), leg, D, hint, R

    printf "%s%s%d breaches%s   %s%.0f%% of cycles%s\n", lab("control"), \
      (NBR ? YEL : GRN), NBR, R, D, NBR * 100 / N, R
    printf "%s%s%d gap rewrites%s   %s%.0f%% of cycles, costing ~%s - %.0f%% of everything%s\n\n", \
      lab(""), (NGR ? RED : GRN), NGR, R, D, NGR * 100 / N, hum(GRW), GRW * 100 / TW, R
    # A quiet fortnight leaves the prior week too thin to compare against, so it
    # widens to everything older rather than reporting a swing measured off two
    # cycles.
    if (B7N < 5) { B7 += C7; B7G += C7G; B7O += C7O; B7N += C7N; B7C += C7C }
    if (A7N >= 5 && B7N >= 5) {
      aw = A7G / A7N / 1000; bw = B7G / B7N / 1000
      ao = A7O * 100 / A7;  bo = B7O * 100 / B7
      ac = A7C / A7N;       bc = B7C / B7N
      printf "%s%slast 7 days against the stretch before them%s\n", lab("trend"), D, R
      printf "%s%sspend/cycle%s    %.0fk %s %s%.0fk%s   %s   %sabove the ~%.0fk floor%s\n", lab(""), D, R, bw, arrow, B, aw, R, delta(bw, aw, 1), D, floor, R
      printf "%s%soutput share%s   %.0f%% %s %s%.0f%%%s   %s\n", lab(""), D, R, bo, arrow, B, ao, R, delta(bo, ao, 0)
      printf "%s%sper cycle%s      %.2f %s %s%.2f%s %sbreaches+rewrites%s   %s\n", lab(""), D, R, bc, arrow, B, ac, R, D, R, delta(bc, ac, 1)
      # Graded against the corpus medians, NOT against the previous window -
      # the arrows above already carry the movement. If this graded against
      # last week instead, a C here and a C on the sessions tab would be two
      # different claims, and the whole point of a letter is that it means one
      # thing wherever it appears.
      g1 = grade(aw, p_wpc, 1); g2 = grade(ao, p_prod, 0); g3 = ctlgrade(ac)
      printf "%s%sgraded%s         %s%s%s spend   %s%s%s production   %s%s%s control   %sagainst your own median%s\n\n", \
        lab(""), D, R, gcol(g1), g1, R, gcol(g2), g2, R, gcol(g3), g3, R, D, R }

    if (planwk + 0 > 0 || plan5 + 0 > 0) {
      printf "%s", lab("plan")
      if (plan5 + 0 > 0) printf "%s5h%s %s%.0f%%%s %sof $%.2f%s   ", D, R, B, usd(T5H) * 100 / plan5, R, D, plan5, R
      else               printf "%s5h%s %s~$%.2f%s   ", D, R, B, usd(T5H), R
      if (planwk + 0 > 0) printf "%s7d%s %s%.0f%%%s %sof $%.2f%s\n\n", D, R, B, usd(A7) * 100 / planwk, R, D, planwk, R
      else                printf "%s7d%s %s~$%.2f%s\n\n", D, R, B, usd(A7), R }
    else {
      printf "%s%s5h ~$%.2f   7d ~$%.2f%s\n", lab("plan"), D, usd(T5H), usd(A7), R
      printf "%s%sno plan ceiling set - nothing on disk records one. Run /usage in Claude Code,%s\n", lab(""), D, R
      printf "%s%sset TOKEN_PLAN_WEEK_USD so the two agree, and these become percentages.%s\n\n", lab(""), D, R }

    # ---------------------------------------------------------------- projects
    # Every other block here answers "how was it spent"; this one answers "on
    # what", which is the only question on the tab whose answer is not already
    # somewhere in the history CSV - it has no project column, so the mapping
    # comes from where each transcript is filed (see proj_rows).
    #
    # Bar LENGTH is the share of all-time spend and bar COLOUR is the same
    # output/write/read split the top of the tab uses, because the two say
    # different things and one bar can carry both: a project can be the largest
    # line on the page and still be mostly blue, which means the money went on
    # holding windows open rather than on work, and that is a different fix from
    # a project that is mostly green.
    pm = 0
    for (k in PJW) { pm++; pk[pm] = k }
    for (i = 2; i <= pm; i++) {
      kt = pk[i]
      for (j = i - 1; j >= 1 && PJW[pk[j]] < PJW[kt]; j--) pk[j + 1] = pk[j]
      pk[j + 1] = kt }
    if (pm > 0) {
      printf "%s%swhere the spend went, by project%s   %s%d project%s, bar is its share of all time%s\n", \
        lab("projects"), D, R, D, pm, (pm == 1 ? "" : "s"), R
      for (i = 1; i <= pm && i <= 6; i++) {
        k = pk[i]
        # The share bar is drawn to its own length and then padded out with the
        # empty glyph, so the right-hand columns stay in line down the block
        # while the bars themselves stay comparable to each other.
        n = int(PJW[k] / TW * 16 + 0.5)
        if (n > 16) n = 16
        if (n < 1) n = 1
        printf "%s%s%s%s  %s%s%s%s  %s%s%s %s%3.0f%%%s  %s~$%-4.0f %3d cyc %2d ses%s   %s7d%s %s%s%s\n", \
          lab(""), GRY, pad(ell(k, 18), 18), R, \
          splitbar(PJO[k], PJR[k], PJD[k], n), D, rep(empt, 16 - n), R, \
          B, pad(hum(PJW[k]), 6), R, B, PJW[k] * 100 / TW, R, \
          D, usd(PJW[k]), PJN[k], PJS[k], R, \
          D, R, (PJ7[k] > 0 ? B : D), (PJ7[k] > 0 ? hum(PJ7[k]) : "-"), R }
      if (pm > 6) printf "%s%s%d more, none above %.0f%% of the total%s\n", \
        lab(""), D, pm - 6, PJW[pk[7]] * 100 / TW, R
      printf "\n" }

    m = 0
    for (k in sw) { m++; kk[m] = k }
    for (i = 2; i <= m; i++) {
      kt = kk[i]
      for (j = i - 1; j >= 1 && sw[kk[j]] < sw[kt]; j--) kk[j + 1] = kk[j]
      kk[j + 1] = kt }
    # "10% of cycles carry a third of the output" is only actionable once you
    # can see WHICH ten percent - so the dearest individual cycles are named,
    # with the date and the session, and their output and growth split out. The
    # session list below answers a different question (where the time went);
    # this one answers what to stop doing.
    # ---------------------------------------------------------------- patterns
    # Three things the record says about how these sessions are run that no
    # single session could ever show you. Each is one number and one move.
    #
    # 1. The floor paid for nothing. A session that answers one or two prompts
    #    and closes still paid the full cold start at the write rate, and it is
    #    the highest-multiple waste there is: the floor is ~2/3 of what those
    #    sessions cost in total.
    for (k in sn) { NSES++; if (sn[k] <= 2) { SHORT++; SHW += sw[k]; SHO += so[k] } }
    if (NSES > 0 && SHORT > 0) {
      printf "%s%s%d of %d sessions ran 2 cycles or fewer%s   %s%.0f%% of every session opened%s\n", \
        lab("patterns"), (SHORT * 100 / NSES >= 30 ? YEL : B), SHORT, NSES, R, D, SHORT * 100 / NSES, R
      printf "%s%s%s of spend, %.0f%% of it output. Each paid the ~%.0fk floor to answer a prompt or two%s\n", \
        lab(""), D, hum(SHW), (SHW > 0 ? SHO * 100 / SHW : 0), floor, R
      printf "%s%s%sask the small ones in a window already warm - a new one costs ~%.0fk before it speaks%s\n", \
        lab(""), GRN, "", floor * 2, R }

    # 2. Rewrites are not spread across sessions, they concentrate in a few - a
    #    window parked once tends to get parked again, and each repeat pays the
    #    whole window over.
    for (k in GRS) { GSES++; if (GRS[k] >= 2) { GREP++; GRPC += GRS[k] } }
    if (NGR > 0 && GSES > 0) {
      printf "%s%s%d of %d rewritten sessions were rewritten twice or more%s   %s%d of %d rewrites, %.0f%%%s\n", \
        lab(""), (GRPC * 100 / NGR >= 40 ? YEL : B), GREP, GSES, R, D, GRPC, NGR, GRPC * 100 / NGR, R
      printf "%s%s%sthe same windows keep being left open - park the ones you have abandoned before%s\n", \
        lab(""), GRN, "", R }

    # 3. Output per cycle falls as a session runs on. Banded in fifths of each
    #    each session by its own length, so a long session and a short one give
    #    same shape rather than the long one dominating the tail. This is the
    #    evidence under the heat column: rent rises with the window AND the work
    #    it returns falls, and the two meet.
    for (i = 1; i <= N; i++) SLEN[PS[i]]++
    for (i = 1; i <= N; i++) {
      if (SLEN[PS[i]] < 6) continue
      fi = int(5 * (PC[i] - 1) / SLEN[PS[i]]); if (fi > 4) fi = 4
      FO[fi] += PO[i]; FN[fi]++ }
    if (FN[0] >= 5 && FN[4] >= 5) {
      f1 = FO[0] / FN[0]; f5 = FO[4] / FN[4]
      printf "%s%soutput per cycle, first fifth of a session to last%s  %s%s%s %s %s%s%s %s%s%s\n", \
        lab(""), D, R, B, hum(f1), R, arrow, (f5 < f1 * 0.75 ? YEL : B), hum(f5), R, \
        D, (f5 < f1 * 0.75 ? sprintf("%.0f%% less", (f1 - f5) * 100 / f1) : "flat"), R
      if (f5 < f1 * 0.75)
        printf "%s%s%sit returns less per cycle while costing more to hold - that is the heat column%s\n", \
          lab(""), GRN, "", R }
    printf "\n"

    printf "%s%sthe dearest single cycles%s   %swhat drove each one is the column that is large%s\n", \
      lab("cycles"), D, R, D, R
    for (i = 1; i <= 5; i++) {
      if (cw[i] <= 0) continue
      # out / growth / window, side by side, because the three are three
      # different diagnoses and the total cannot tell them apart. A dear cycle
      # with a small output and a small growth was not an expensive prompt at
      # all - it was rent on a window that had already got big, and the fix for
      # that is upstream of anything you could have typed in it.
      printf "%s%s%s%s  %s%s%s  %sout%s %s %sgrow%s %s%s%s %swin%s %s%s%s  %s%s%s\n", lab(""), \
        B, pad(hum(cw[i]), 6), R, GRY, substr(ct[i], 6, 11), R, \
        D, R, pad(hum(co[i]), 5), \
        D, R, (cg[i] > gbud ? YEL : ""), pad(hum(cg[i]), 5), R, \
        D, R, (cb[i] > 200000 ? YEL : ""), pad(hum(cb[i]), 5), R, \
        D, ell((cs[i] in TT) ? TT[cs[i]] : cs[i], TXW - 52), R }
    printf "\n"

    printf "%s%sby weighted spend, all time%s\n", lab("dearest"), D, R
    for (i = 1; i <= 5 && i <= m; i++) {
      k = kk[i]
      printf "%s%s%s%s  %s%s%s  %s%d cyc%s  %s%s%s\n", lab(""), B, pad(hum(sw[k]), 6), R, \
        GRY, k, R, D, sn[k], R, D, ell((k in TT) ? TT[k] : "-", TXW - 30), R }

    if (watch) printf "\n  %s%s%s\n", D, "w  daily/weekly   d  detail   esc  back to sessions   r  refresh   q  quit", R
    else printf "\n" }
  ' <(hist_rows) | frame_blocks "$AW" "${ROWS:-40}" "${APAGE:-1}" "${PGFILE:-}"
}

now_s() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# A desktop notification, because the bell is easy to miss and this pane spends
# most of its life behind something else. This is the entire replacement for the
# retired pinger: it cannot renew a window, it can only get you to act while
# acting is still cheap - which measurement said was the better move anyway.
#
# Title and body travel as environment variables rather than being interpolated
# into the PowerShell string. A session's first prompt is arbitrary user text and
# would otherwise only need one apostrophe to break the quoting, or worse.
#
# Fired detached: the balloon needs its process alive for the duration it is on
# screen, and the pane redraws once a second. TOKEN_POPUP=0 turns it off.
notify() {
  local title="$1" body="$2" pid="${3:-0}"
  [ "$POPUP" = 1 ] || return 0
  command -v powershell >/dev/null 2>&1 || return 0
  # Clicking the balloon focuses the window that session lives in. The pid we
  # track is the CLAUDE process, and a CLI running inside VS Code's terminal owns
  # no window of its own - so this walks up the parent chain until it finds an
  # ancestor that has one. For an IDE session that ancestor is the VS Code
  # window; for a standalone one it is the terminal. Right in both cases.
  ( export TN_TITLE="$title" TN_BODY="$body" TN_PID="$pid"
    powershell -NoProfile -NonInteractive -Command '
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing
      function Focus-Owner([int]$start) {
        $q = $start
        for ($i = 0; $i -lt 8 -and $q -gt 0; $i++) {
          try { $proc = Get-Process -Id $q -ErrorAction Stop } catch { return }
          if ($proc.MainWindowHandle -ne 0) {
            try { (New-Object -ComObject WScript.Shell).AppActivate($q) | Out-Null } catch { }
            return
          }
          $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$q" -ErrorAction SilentlyContinue
          if (-not $ci) { return }
          $q = [int]$ci.ParentProcessId
        }
      }
      $ni = New-Object System.Windows.Forms.NotifyIcon
      $ni.Icon = [System.Drawing.SystemIcons]::Warning
      $ni.Visible = $true
      $script:hit = $false
      $ni.add_BalloonTipClicked({ $script:hit = $true })
      $ni.ShowBalloonTip(20000, $env:TN_TITLE, $env:TN_BODY, "Warning")
      # DoEvents, not Start-Sleep alone: a sleeping process pumps no window
      # messages, so the click would never arrive and the balloon would be
      # decoration. This is the difference between clickable and merely visible.
      $stop = (Get-Date).AddSeconds(25)
      while ((Get-Date) -lt $stop -and -not $script:hit) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 120
      }
      if ($script:hit -and $env:TN_PID -match "^[0-9]+$") { Focus-Owner ([int]$env:TN_PID) }
      $ni.Dispose()' >/dev/null 2>&1 ) &
}

# The last five minutes of a window's cache life, said out loud.
#
# Everything else here is something you read when you happen to look. This is
# the one moment where looking is the whole problem: the choice between carrying
# a window and paying 2x for it closes on a clock you cannot see from another
# terminal, and it closes silently. So the tool makes a noise instead.
#
# Three rules keep it from becoming noise itself:
#   - one ring per session per lapse. It re-arms only when that window goes warm
#     again, so a session sitting at 2m does not ring on every collect;
#   - nothing rings for a window not worth saving. Under the parking bar a lapse
#     costs less than acting on it would, so there is nothing to warn about;
#   - the first collect primes the map without ringing. The bell reports a
#     CHANGE; a session already inside the window when you opened the pane is
#     something you can see on screen, and a bell at startup is just a fright.
declare -A RUNG
BELL_PRIMED=0
ring_bell() {
  local sid al idle lf ctx name trend pid proj title rest hit=0 body="" nm hitpid=0
  [ "$BELL" = 1 ] || return 0
  while IFS='|' read -r sid al idle lf ctx name trend pid proj title rest; do
    case "$sid" in '#'*|'') continue ;; esac
    [ "$al" = 1 ] || continue
    case "$lf$ctx" in *[!0-9-]*) continue ;; esac
    if [ "$lf" -gt 0 ] && [ "$lf" -le "$BELL_MIN" ] && [ "$(( ctx / 1000 ))" -ge "$BELL_CTX" ]; then
      if [ -z "${RUNG[$sid]:-}" ]; then
        RUNG[$sid]=1; hit=1
        [ "$hitpid" = 0 ] && hitpid="$pid"
        # The first prompt, not the sid: it is the only label you would
        # recognise from a notification with no pane in front of you.
        nm=${title//\'/}
        body="${body}${nm:0:44}  -  $(( ctx / 1000 ))k, ${lf}m left"$'\n'
      fi
    elif [ "$lf" -gt "$BELL_MIN" ]; then
      unset "RUNG[$sid]"
    fi
  done < "$SNAP"
  if [ "$BELL_PRIMED" = 0 ]; then BELL_PRIMED=1; return 0; fi
  if [ "$hit" = 1 ]; then
    printf '\a'
    notify "Prompt cache lapsing" "${body}Click to jump there. Type anything to hold it, or /park then /clear." "$hitpid"
  fi
  return 0
}
# Take a session log out of the list.
#
# A trash directory, not rm. A transcript is the only record a session ever
# leaves, and the reason to remove one is almost always tidiness rather than
# regret - so emptying deleted-sessions/ by hand stays a separate, deliberate
# act. This step is reversible; that one is not.
#
# A live session is refused outright rather than warned about. Its process holds
# that file open and appends to it, so taking it away mid-session damages work
# that is still happening. No confirmation flow makes that a good idea.
delete_log() {
  local row="$1" rec short al sid tf dest f
  [ "$row" -gt 0 ] || return 1
  rec=$(awk -F'|' -v r="$row" '!/^#/ { c++; if (c == r) { print $1 "|" $2 "|" $15 "|" $16; exit } }' "$VSNAP")
  short=${rec%%|*}; rec=${rec#*|}
  al=${rec%%|*};    rec=${rec#*|}
  sid=${rec%%|*};   tf=${rec#*|}
  [ -n "$short" ] || return 1
  [ "$al" = 1 ] && return 2
  [ -n "$tf" ] && [ -f "$tf" ] || return 1
  dest="$CL/deleted-sessions"
  mkdir -p "$dest" 2>/dev/null
  mv -f "$tf" "$dest/" 2>/dev/null || return 1
  # Every cache keyed by this session goes too, or the next collect rebuilds the
  # row from them and the log returns as a ghost with no transcript behind it.
  for f in "$TITLES" "$NICKS" "$META"; do
    [ -f "$f" ] || continue
    if awk -F'\t' -v a="$short" -v b="$sid" '$1 != a && $1 != b' "$f" > "$f.$$" 2>/dev/null
    then mv -f "$f.$$" "$f" 2>/dev/null
    else rm -f "$f.$$" 2>/dev/null
    fi
  done
  return 0
}


# Move a session on to its next nickname. Only an INDEX is stored - the name
# itself is derived in the renderer from the session's own prompts, so it keeps
# up with a session that is still talking, and the last variant wraps back to
# the default rather than needing a second key to undo it.
#
# What this deliberately does NOT touch is sessions/<pid>.json: the CLI's name
# for a session is the CLI's business, and a tool that reads state has no
# business writing into the state it reads.
# Is there a newer release, and would you like it. Three small functions, kept
# apart because they fail in different ways and only the first one can hang.
#
# The check is DETACHED on purpose. A pane that blocks for four seconds on a
# flaky network at startup is worse than a pane that never mentions updates at
# all, so nothing here is ever waited on: the fetch writes a file, and whatever
# is in that file is what the next frame reports. The first run of a day
# therefore says nothing, and the run after it says what the fetch found. That
# is the right trade for a background courtesy.
version_check() {
  [ "$UPDCHECK" = 1 ] || return 0
  [ -n "$UPDREPO" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local now last=0
  now=$(now_s)
  [ -f "$UPDSTATE" ] && last=$(awk -F'\t' 'END { print $1 + 0 }' "$UPDSTATE" 2>/dev/null)
  [ $(( now - last )) -ge "$UPDEVERY" ] || return 0
  # Stamped BEFORE the fetch, so a network that hangs every time still only
  # costs one attempt a day rather than one per launch.
  printf '%s\t%s\n' "$now" "$(remote_version_cached)" > "$UPDSTATE" 2>/dev/null
  {
    v=$(curl -fsS -m 4 \
      "https://raw.githubusercontent.com/$UPDREPO/$UPDBRANCH/VERSION" 2>/dev/null \
      | tr -d ' \r\n')
    # Only a plausible version replaces what is on disk. A captive-portal login
    # page is a 200 with a body, and without this it would become the version.
    case "$v" in
      [0-9]*.[0-9]*.[0-9]*) printf '%s\t%s\n' "$(now_s)" "$v" > "$UPDSTATE" 2>/dev/null ;;
    esac
  } >/dev/null 2>&1 &
}

remote_version_cached() {
  [ -f "$UPDSTATE" ] || return 0
  awk -F'\t' 'END { print $2 }' "$UPDSTATE" 2>/dev/null
}

# The remote version if it is newer than this copy, and nothing otherwise.
# Compared field by field as numbers - a string compare calls 1.10.0 older than
# 1.9.0, which is exactly the release where you would want to hear about it.
update_available() {
  local r; r=$(remote_version_cached)
  [ -n "$r" ] || return 1
  [ "$r" != "$TSVER" ] || return 1
  awk -v a="$TSVER" -v b="$r" '
    BEGIN {
      na = split(a, A, "."); nb = split(b, B, ".")
      n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        x = A[i] + 0; y = B[i] + 0
        if (y > x) { print b; exit }
        if (x > y) exit } }'
}

# Updating is a git pull in the clone plus a re-run of its installer, which is
# only possible if we know where that clone is - install.sh records it. Without
# that file there is nothing to pull, so this says what to type instead of
# guessing at a path and failing halfway through an overwrite.
do_update() {
  local src out
  [ -f "$SRCFILE" ] && src=$(head -1 "$SRCFILE" 2>/dev/null)
  if [ -z "${src:-}" ] || [ ! -d "$src/.git" ]; then
    FLASH="no clone recorded - update by hand: git pull, then ./install.sh"
    return 0
  fi
  out=$(git -C "$src" pull --ff-only 2>&1) || {
    FLASH="pull failed in $src - $(printf '%s' "$out" | tail -1)"; return 0; }
  if bash "$src/install.sh" >/dev/null 2>&1; then
    FLASH="updated - restart this pane to run the new version"
    : > "$UPDSTATE"
  else
    FLASH="pulled, but install.sh failed - run it by hand in $src"
  fi
}

# One writer for token-nicks.tsv, so the file can only ever hold one shape:
#
#   sid <TAB> variant <TAB> typed-name
#
# The third field is optional and older two-field rows keep working, which is
# the whole reason it went on the end rather than into a second file.
write_nick() {  # write_nick <sid> <variant> [typed name]
  local sid="$1" v="$2" nm="${3:-}" tmp
  [ -n "$sid" ] || return 0
  tmp="$NICKS.$$"
  { [ -f "$NICKS" ] && grep -v "^$sid$(printf '\t')" "$NICKS"
    if [ -n "$nm" ]; then printf '%s\t%s\t%s\n' "$sid" "$v" "$nm"
    else                  printf '%s\t%s\n'     "$sid" "$v"; fi
  } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$NICKS" 2>/dev/null
}

# The variant a row is on, and the name typed for it if there is one. Both read
# back rather than remembered, because the file is the state and a second copy
# of it in a shell variable is a second thing to get wrong.
nick_var() {  # nick_var <sid>
  [ -f "$NICKS" ] || { echo 0; return 0; }
  awk -F'\t' -v s="$1" '$1 == s { v = $2 + 0 } END { print v + 0 }' "$NICKS"
}
typed_nick() {  # typed_nick <sid>
  [ -f "$NICKS" ] || return 0
  awk -F'\t' -v s="$1" '$1 == s { print $3; exit }' "$NICKS"
}

reroll_nick() {
  local row="$1" sid v
  [ "$row" -gt 0 ] || return 0
  sid=$(row_field "$row" 1)
  [ -n "$sid" ] || return 0
  v=$(nick_var "$sid")
  # A typed name is not a variant, so it cannot be advanced past. n clears it
  # and hands the row back to the derived pool at the variant it left off on,
  # which means one key both undoes /n and resumes re-rolling.
  if [ -n "$(typed_nick "$sid")" ]; then write_nick "$sid" "$v" ""; return 0; fi
  write_nick "$sid" "$(( (v + 1) % NVAR ))" ""
}

# /n NAME, typed at the prompt line that / opens. The name is the rest of the
# line: leading and trailing blanks go, and any run of blanks inside becomes a
# single dash, so a name typed as three words still arrives as one token and the
# column stays a column. A bare /n clears back to the derived name.
#
# Sanitised for the two delimiters this program is built on - the snapshot is
# pipe-separated and this file tab-separated, so neither may reach a stored name
# - and cut to the width a row can actually show.
set_nick() {  # set_nick <row> <raw text>
  local row="$1" raw="$2" sid nm
  [ "$row" -gt 0 ] || return 0
  sid=$(row_field "$row" 1)
  [ -n "$sid" ] || return 0
  nm=$(printf '%s' "$raw" | tr '|\t' '  ' \
       | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's/[[:space:]][[:space:]]*/-/g')
  nm=${nm:0:24}
  write_nick "$sid" "$(nick_var "$sid")" "$nm"
}

# What is parked, newest first. Read by a person deciding what to resume, and by
# /park deciding whether this session's work is a topic that already has a file
# or a new one - which is the whole reason a project may hold several.
list_checkpoints() {
  local now cf sid task line w proj hit=0
  now=$(now_s)
  scan_checkpoints
  proj="$CKPROJ"
  [ -n "$proj" ] || { proj=${PWD//\\//}; proj=${proj%/}; proj=${proj##*/}; }
  w=$(( ${COLUMNS:-92} - 20 )); [ "$w" -lt 40 ] && w=40

  printf '\n  %sPARKED%s  %s%s%s\n\n' "$C_B" "$C_R" "$C_DIM" \
    "$([ "$proj" = all ] && echo "every project" || echo "$proj")" "$C_R"
  for cf in "${CKN[@]}"; do
    if [ "$proj" != all ]; then
      case "$cf" in "$proj".md|"$proj".*.md) ;; *) continue ;; esac
    fi
    hit=1
    if [ "$proj" = all ]; then
      topic_of "$cf" "${cf%%.*}"; TOPIC="${cf%%.*}/$TOPIC"
    else topic_of "$cf" "$proj"; fi
    agestr $(( (now - ${CK[$cf]}) / 60 ))
    sid=${CS[$cf]:0:8}; [ -n "$sid" ] || sid="unstamped"
    printf '  %s%s%s %s%-22s%s %s%-5s%s %s%s%s\n' \
      "$C_BLU" "$G_PARK" "$C_R" "$C_B" "$TOPIC" "$C_R" "$C_GRY" "$AGE" "$C_R" \
      "$C_DIM" "$sid" "$C_R"
    task=${CKT[$cf]}
    [ -n "$task" ] && printf '    %s%s%s\n' "$C_DIM" "${task:0:$w}" "$C_R"
    printf '    %s%s/checkpoints/%s%s\n' "$C_GRY" "$CL" "$cf" "$C_R"
  done
  if [ "$hit" != 1 ]; then
    # "nothing parked" is only true if nothing is parked ANYWHERE. Said while a
    # dozen checkpoints sit on disk under other project names, it is a lie that
    # sends you off to re-derive work you already paid to save. The usual way to
    # hear it is running this from the wrong directory - easy, silent, and
    # indistinguishable from genuinely having none.
    other=0
    for cf in "$CL"/checkpoints/*.md; do [ -e "$cf" ] && other=$((other + 1)); done
    if [ "$proj" != all ] && [ "$other" -gt 0 ]; then
      printf '  %snothing parked for %s%s%s, but %d exist elsewhere%s\n'         "$C_DIM" "$C_B" "$proj" "$C_DIM" "$other" "$C_R"
      printf '  %s--checkpoints all lists them, or cd to that project first%s\n' "$C_GRY" "$C_R"
    else
      printf '  %snothing parked%s\n' "$C_DIM" "$C_R"
    fi
  fi
  printf '\n'
}

if [ "$CKLIST" = 1 ]; then list_checkpoints; exit 0; fi

# Width is read the same way in all three entry points, and only here - tput
# first because COLUMNS is not exported by every shell, the variable second.
arrange() {
  SORTNAME=""
  [ "$SORT" -gt 0 ] && SORTNAME="${SORTS[$SORT]}"
  ARRDIRTY=0
  # The default order is the one collect() already wrote - lapse-soonest - so
  # the common case copies rather than sorting.
  if [ "$SORT" = 0 ] && [ -z "$FILTER" ]; then cp -f "$SNAP" "$VSNAP" 2>/dev/null; return; fi
  awk -F'|' -v s="$SORT" -v f="$FILTER" -v rpc="$RPC" '
    /^#/ { print; next }
    {
      # Matched against the CLI name, the project, the opening prompt and the
      # transcript path - the four things you would think to type. Case
      # insensitively, because nobody types a project name in caps.
      #
      # By PROJECT rather than by the displayed name, for the sort: the name
      # in the table is a nickname the renderer derives from the prompts, and
      # it is not in the snapshot to sort on. Project is, it is stable, and
      # grouping the windows of one repo together is the question this order
      # actually gets asked.
      if (f != "") {
        hay = tolower($6 " " $9 " " $10 " " $16)
        if (index(hay, tolower(f)) == 0) next }
      k = 0
      if      (s == 1) k = 99999999 - $5
      else if (s == 2) k = 99999999 - ($12 * 5 + $25 * 2 + $5 * rpc * 0.1 * $11)
      else if (s == 3) k = $3
      if (k < 0) k = 0
      # Closed sessions stay under the live ones whatever the key is. They are a
      # footnote; interleaving them by size would put a dead window above a
      # decision.
      printf "%d|%015d|%s\n", (($2 + 0 == 1) ? 0 : 1), k, $0 }' "$SNAP" 2>/dev/null \
    | { if [ "$SORT" = 4 ]; then sort -t'|' -k1,1n -k11,11f
        else sort -s -t'|' -k1,1n -k2,2n; fi } \
    | cut -d'|' -f3- > "$VSNAP"
}

# One field of the selected row, addressed the way you are looking at the list.
row_field() {
  [ "${1:-0}" -gt 0 ] || return 1
  awk -F'|' -v r="$1" -v f="$2" '!/^#/ { c++; if (c == r) { print $f; exit } }' "$VSNAP" 2>/dev/null
}

# The pane spends every row telling you to go and do something in a terminal it
# cannot reach. These two shorten that: one puts the resume command on the
# clipboard, the other opens what you would go looking for next.
copy_resume() {
  local sid; sid=$(row_field "$1" 15); [ -n "$sid" ] || { FLASH="nothing to copy"; return; }
  if   command -v clip.exe >/dev/null 2>&1; then printf 'claude -r %s' "$sid" | clip.exe
  elif command -v clip     >/dev/null 2>&1; then printf 'claude -r %s' "$sid" | clip
  elif command -v pbcopy   >/dev/null 2>&1; then printf 'claude -r %s' "$sid" | pbcopy
  else FLASH="no clipboard on this machine: claude -r ${sid}"; return; fi
  FLASH="copied  claude -r ${sid:0:8}..."
}

open_row() {
  local f; f=$(row_field "$1" 21)                      # the /park checkpoint
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    f=$(row_field "$1" 16); f="${f%/*}"                # else the transcript folder
  fi
  [ -n "$f" ] && [ -e "$f" ] || { FLASH="nothing to open for this row"; return; }
  if command -v cygpath >/dev/null 2>&1 && command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$(cygpath -w "$f")" 2>/dev/null || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$f" >/dev/null 2>&1 &
  elif command -v open     >/dev/null 2>&1; then open "$f" >/dev/null 2>&1 &
  else FLASH="cannot open: $f"; return; fi
  FLASH="opened ${f##*/}"
}

term_cols() {
  COLS=$( (tput cols) 2>/dev/null ) || COLS=""
  [ -n "$COLS" ] || COLS="${COLUMNS:-92}"
  # How TALL the window is, which until now nothing here asked. A pane that
  # redraws in place cannot scroll, so anything past the last row is not merely
  # inconvenient - it is invisible, and the analytics tab ran to 83 lines in a
  # 40-row window. Both views now shed their least important parts to fit, and
  # say what they dropped.
  ROWS=$( (tput lines) 2>/dev/null ) || ROWS=""
  [ -n "$ROWS" ] || ROWS="${LINES:-40}"
  case "$ROWS" in *[!0-9]*|"") ROWS=40 ;; esac
  [ "$ROWS" -lt 12 ] && ROWS=12
}

# One-shot goes to a scrollback, which scrolls - so there is nothing to page
# around and nothing to shed. Only the pane, which redraws in place, is bound by
# the height of the window.
if [ "$ANALYTICS" = 1 ] && [ "$WATCH" = 0 ]; then term_cols; ROWS=99999; analytics; exit 0; fi

# Asked and answered before anything is collected - neither question needs a
# snapshot, and --update in particular should not spend a second reading the
# disk before it replaces the very script doing the reading.
if [ "$VERSIONQ" = 1 ]; then
  printf 'token-sessions.sh %s\n' "$TSVER"
  [ -n "$UPDREPO" ] && printf 'updates: https://github.com/%s\n' "$UPDREPO"
  r=$(remote_version_cached)
  [ -n "$r" ] && printf 'latest seen: %s\n' "$r"
  exit 0
fi
if [ "$UPDATEQ" = 1 ]; then
  FLASH=""
  do_update
  printf '%s\n' "$FLASH"
  exit 0
fi

if [ "$WATCH" = 1 ]; then
  ESC=$(printf '\033')
  SNAP=$(mktemp 2>/dev/null) || SNAP="$CL/.token-sessions.snap.$$"
  VSNAP="$SNAP.view"; PGFILE="$SNAP.pages"
  printf '\033[?1049h\033[?25l'                    # alt screen, hide cursor
  trap 'printf "\033[?25h\033[?1049l"; rm -f "$SNAP" "$VSNAP" "$PGFILE"; exit 0' INT TERM EXIT

  # Two clocks, deliberately separate. Collecting reads the disk and costs a
  # second or so, so it runs only on DEADLINE - every EVERY seconds, or when
  # you press r. Drawing costs one awk, so it runs every second: that keeps the
  # countdown live and makes every key land immediately on the data already in
  # hand. No key re-reads anything (a re-collects, because it changes what
  # there is to read), and any key pushes the deadline out, so a refresh never
  # yanks the view a moment after you asked for it.
  # VIEW is which tab is on screen: 0 sessions, 1 analytics. It is deliberately
  # not a mode with its own loop - the analytics tab redraws on the same clock
  # and answers the same keys, so t and esc cost nothing to hold.
  DEADLINE=0; N=0; SECS=0; COLS=92; QUIT=0; VIEW=$ANALYTICS; HELPV="${TOKEN_KEYS:-0}"; DELCONF=""
  NUMBUF=""; FLASH=""; APAGE=1
  # Fired once at startup and never waited on. What it finds is picked up on a
  # later frame, or on a later day - see version_check for why that is the point.
  version_check
  UPDNEW=$(update_available); UPDDISMISS=0
  # TICK is the animation frame, ANYRUN whether anything is worth animating for.
  # Both are cheap: TICK is an increment, ANYRUN one pass over the snapshot that
  # was just written, so neither adds a disk read.
  TICK=0; ANYRUN=0; RATE="$EVERY"
  # 0 = the list and nothing else: one line per row saying what state the window
  # is in and what to do about it. 1 opens the detail panel for the selected row
  # and puts the prompt and the reasoning behind the verdict under that row.
  # Off is the default because the list at a glance is the only way this pane is
  # ever read - detail is something you ask for, with d, about one row.
  DETAIL="${DETAIL:-0}"
  while true; do
    NOW=$(now_s)
    if [ "$NOW" -ge "$DEADLINE" ]; then
      snapshot > "$SNAP"
      ARRDIRTY=1
      ring_bell
      term_cols
      # Field 18 is the running flag - the same one the renderer reads.
      ANYRUN=$(awk -F'|' '!/^#/ && $18 + 0 == 1 { c++ } END { print c + 0 }' "$SNAP" 2>/dev/null)
      ANYRUN=$((ANYRUN + 0))
      # Running is decided at collect time, off transcript and history mtimes -
      # so on the ordinary minute-long clock a marker could go on animating for
      # most of a minute after the turn it describes had finished, which is an
      # animation telling you something false. While anything is in flight the
      # collect tightens to 10s; the disk pass is local and only happens while
      # you are watching a session actually work.
      RATE="$EVERY"
      [ "$ANYRUN" -gt 0 ] && [ "$RATE" -gt 10 ] && RATE=10
      DEADLINE=$(( $(now_s) + RATE ))
      NOW=$(now_s)
    fi
    # Rows, not lines: the snapshot can carry counter lines the renderer skips,
    # and a selection that can run one past the last session is a panel drawn
    # from an empty row. Counted off the VIEW, because a filter changes how many
    # rows there are to select between.
    if [ "$ARRDIRTY" = 1 ]; then
      arrange
      N=$(grep -cv '^#' "$VSNAP" 2>/dev/null); N=$((N + 0))
    fi
    [ "$SEL" -gt "$N" ] && SEL="$N"
    SECS=$((DEADLINE - NOW)); [ "$SECS" -lt 0 ] && SECS=0
    # One frame per repaint, counted here rather than beside the key read: the
    # no-tty path continues out of the loop before it ever gets that far, and a
    # counter that only advances when a keyboard is attached is a counter the
    # animation cannot be tested with.
    TICK=$((TICK + 1))
    if [ "$VIEW" = 1 ]; then
      out=$(analytics)
      # Clamp to what the tab actually had, so ] past the last page is a no-op
      # rather than a counter that then needs the same number of [ to unwind.
      if [ -s "$PGFILE" ]; then read -r _p _t < "$PGFILE"; APAGE=$((_p + 0)); fi
    else out=$(render "$VSNAP" "$SEL"); fi
    # Erase to end of line as each line is drawn, and to end of screen once at
    # the bottom. A blanket clear first would flicker at this redraw rate.
    printf '\033[H%s\033[0J' "${out//$'\n'/$ESC[K$'\n'}"

    # Without a tty every read returns EOF at once and the loop would spin.
    if [ ! -t 0 ]; then sleep "$EVERY"; continue; fi

    # Drain whatever is buffered before drawing again. Holding j otherwise
    # queues one full redraw per repeat and the selection crawls behind your
    # finger; this collapses a burst into a single frame.
    # A quarter of a second only while something is running: that is four awk
    # renders a second instead of one, and it buys the only moving thing on the
    # pane. With nothing in flight there is nothing to animate, so the clock
    # goes back to a second and the pane costs what it always did.
    GOT=0; WAIT=1
    [ "$ANYRUN" -gt 0 ] && WAIT=0.25
    while true; do
      key=""
      IFS= read -rsn1 -t "$WAIT" key || true
      [ -n "$key" ] || break
      # An arrow key arrives as ESC [ A; a bare ESC has no tail and means "back
      # to the overview", so the follow-up read must be able to time out.
      if [ "$key" = "$ESC" ]; then
        rest=""; IFS= read -rsn2 -t 0.05 rest || true
        key="$key$rest"
        # PgUp/PgDn are four bytes, not three: ESC [ 5 ~. Without this the tail
        # arrives on the next pass as a bare ~ and the page never turns.
        case "$key" in "$ESC["[0-9])
          tail=""; IFS= read -rsn1 -t 0.05 tail || true; key="$key$tail" ;;
        esac
      fi
      # Any other key cancels a pending delete. A confirmation that survives
      # you navigating somewhere else is not a confirmation.
      case "$key" in D) ;; *) DELCONF="" ;; esac
      # A half-typed row number is cancelled by anything that is not the rest of
      # it, for the same reason.
      case "$key" in [0-9]) ;; *) NUMBUF="" ;; esac
      case "$key" in *) FLASH="" ;; esac
      case "$key" in
        # Moving the selection is meaningless on a tab that has no rows, so
        # anything that moves it comes back to the sessions view first.
        j|"$ESC[B") VIEW=0; SEL=$((SEL + 1)); [ "$SEL" -gt "$N" ] && SEL="$N" ;;
        k|"$ESC[A") VIEW=0; SEL=$((SEL - 1)); [ "$SEL" -lt 1 ] && SEL=1 ;;
        # Nine rows was the whole address space, and --all lists twelve closed
        # sessions on top of the live ones - so rows past nine could only be
        # reached by holding j. Digits now accumulate, and commit the moment no
        # further digit could name a row that exists, which leaves single-digit
        # jumps as immediate as they have always been on a short list.
        [0-9])      VIEW=0; NUMBUF="$NUMBUF$key"
                    if [ $((10#$NUMBUF * 10)) -gt "$N" ] || [ ${#NUMBUF} -ge 3 ]; then
                      SEL=$((10#$NUMBUF))
                      [ "$SEL" -gt "$N" ] && SEL="$N"
                      [ "$SEL" -lt 1 ] && SEL=1
                      NUMBUF=""
                    fi ;;
        # esc unwinds one step at a time: out of analytics, then out of the
        # detail panel. One key, and never a surprise about which.
        "$ESC")     if [ "$VIEW" = 1 ]; then VIEW=0
                    elif [ "$DETAIL" = 1 ]; then DETAIL=0
                    else SEL=0; fi ;;
        t)          VIEW=$((1 - VIEW)) ;;
        [?])        HELPV=$((1 - HELPV)) ;;
        # The one key that opens detail. Selecting a row used to open the panel
        # by itself, which made moving the selection an expensive act and left
        # this key looking dead - it only ever added a line to rows that already
        # wanted something done, so on a quiet list it did nothing visible. Now
        # it owns both: the panel for the selected row, and the prompt and
        # reasoning under that row. A view toggle, so it costs a redraw, not a
        # collect - the data is already on screen either way.
        d)          DETAIL=$((1 - DETAIL)); VIEW=0
                    if [ "$DETAIL" = 1 ] && [ "$SEL" -lt 1 ] && [ "$N" -gt 0 ]
                      then SEL=1; fi ;;
        g)          VIEW=0; [ "$N" -gt 0 ] && SEL=1 ;;
        G)          VIEW=0; SEL="$N" ;;
        a)          SHOW_ALL=$((1 - SHOW_ALL)); DEADLINE=0 ;;
        # Re-rolls THIS tool's name for the selected row. No collect: the
        # renderer re-reads token-nicks.tsv on every frame, so the next redraw
        # (a second away) shows it.
        D)          if [ "$SEL" -gt 0 ]; then
                      VIEW=0
                      dsid=$(row_field "$SEL" 1)
                      if [ -n "$DELCONF" ] && [ "$DELCONF" = "$dsid" ]; then
                        delete_log "$SEL"; DELCONF=""; SEL=0; DEADLINE=0
                      else DELCONF="$dsid"; fi
                    fi ;;
        n)          if [ "$SEL" -gt 0 ]; then VIEW=0; reroll_nick "$SEL"
                    elif [ "$N" -gt 0 ]; then VIEW=0; SEL=1; reroll_nick 1; fi ;;
        w)          BUCKET=$((1 - BUCKET)); VIEW=1 ;;
        # Order and narrowing, both pure view state: they rewrite the view file
        # and cost no disk read, so they land on the next redraw a second away.
        s)          VIEW=0; SORT=$(( (SORT + 1) % ${#SORTS[@]} )); ARRDIRTY=1; SEL=0 ;;
        # The prompt line is a small command line, not only a filter box. It
        # opens on filter because that is what it is asked for nine times out of
        # ten, and "n NAME" renames the selected row instead - one keystroke
        # away rather than a second key that would have to be found, and in the
        # same place you already type at.
        #
        # The dispatch is on a leading token, so "n" as a filter word is still
        # reachable as "/ n" - the space is what says you meant to search.
        /)          VIEW=0
                    printf '\033[%d;1H\033[K  %s/%s ' "$ROWS" "$C_B" "$C_R"
                    printf '\033[?25h'
                    IFS= read -r PLINE || PLINE=""
                    printf '\033[?25l'
                    case "$PLINE" in
                      n|n[[:space:]]*)
                        # Name the row you are looking at. With nothing selected the
                        # top one is meant - the same rule n itself follows.
                        nrow=$SEL; [ "$nrow" -gt 0 ] || nrow=1
                        if [ "$N" -gt 0 ]; then
                          set_nick "$nrow" "${PLINE#n}"
                          nnm=$(typed_nick "$(row_field "$nrow" 1)")
                          if [ -n "$nnm" ]; then FLASH="named row $nrow $nnm"
                          else FLASH="row $nrow back to its derived name"; fi
                        fi ;;
                      *)  FILTER="$PLINE"; ARRDIRTY=1; SEL=0 ;;
                    esac ;;
        # Paging the analytics tab, which used to compute eleven sections and
        # then throw eight of them away with the advice to buy a taller window.
        "]"|"$ESC[6~") VIEW=1; APAGE=$((APAGE + 1)) ;;
        "["|"$ESC[5~") VIEW=1; APAGE=$((APAGE - 1)); [ "$APAGE" -lt 1 ] && APAGE=1 ;;
        y)          [ "$SEL" -gt 0 ] && { VIEW=0; copy_resume "$SEL"; } ;;
        o)          [ "$SEL" -gt 0 ] && { VIEW=0; open_row "$SEL"; } ;;
        # Muting re-primes rather than just going quiet, so unmuting later does
        # not immediately ring for every window that lapsed while it was off.
        b)          BELL=$((1 - BELL)); BELL_PRIMED=0; RUNG=() ;;
        # Both keys are no-ops when nothing is offered, so neither can surprise
        # you by acting on a stale banner.
        u)          [ -n "${UPDNEW:-}" ] && { VIEW=0; do_update; UPDNEW=""; UPDDISMISS=1; } ;;
        U)          [ -n "${UPDNEW:-}" ] && { VIEW=0; UPDNEW=""; UPDDISMISS=1
                      FLASH="update dismissed for now"; } ;;
        # Arms the fail-safe on the selected row. Takes effect on the next
        # collect, which is also when it could first fire.
        c)          COMPACT=$((1 - COMPACT)) ;;
        r)          DEADLINE=0 ;;
        q)          QUIT=1; break ;;
      esac
      GOT=1; WAIT=0.002
    done
    [ "$QUIT" = 1 ] && break
    # The banner follows the state file rather than a variable set at startup,
    # so a fetch that lands ten seconds into the session still gets seen. U
    # blanks it for this run, and this must not undo that.
    [ "$UPDDISMISS" = 0 ] && UPDNEW=$(update_available)
    # Push the countdown out, but never past a refresh the key itself asked for.
    [ "$GOT" = 1 ] && [ "$DEADLINE" != 0 ] && DEADLINE=$(( $(now_s) + RATE ))
  done
else
  SNAP=$(mktemp 2>/dev/null) || SNAP="$CL/.token-sessions.snap.$$"
  VSNAP="$SNAP.view"; PGFILE="$SNAP.pages"
  trap 'rm -f "$SNAP" "$VSNAP" "$PGFILE"' EXIT
  version_check
  snapshot > "$SNAP"
  arrange
  term_cols
  SECS=0
  UPDNEW=""; UPDDISMISS=0
  render "$VSNAP" "$SEL"
  # A one-shot has no keys, so it can only say where the update is. The pane is
  # where it can be taken, which is what the second line points at.
  upd=$(update_available)
  if [ -n "$upd" ]; then
    printf '\n  %sversion %s is available%s  you have %s\n' "$C_YEL" "$upd" "$C_R" "$TSVER"
    printf '  %stake it with u in --watch, or git pull in the clone%s\n' "$C_DIM" "$C_R"
  fi
fi
