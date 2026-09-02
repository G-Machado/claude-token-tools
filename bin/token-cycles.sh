#!/usr/bin/env bash
# Per-prompt-cycle token usage for the current Claude Code session.
#
# A cycle is one user message plus every tool call and follow-up until control
# returns to the user. "output" is the work signal to calibrate against;
# "re-cached" is accumulated context being rewritten at a cache boundary and
# scales with session length, not with how much the prompt asked for.
#
# Usage:
#   token-cycles.sh [tier|number]   table for this session, scored against a tier
#   token-cycles.sh --alert         Stop-hook mode: reads hook JSON on stdin,
#                                   prints a systemMessage only on a breach
#   token-cycles.sh --stats         history across sessions: how often the hook
#                                   actually fires, and what set it off
#
# Tiers (see the Token budget section of ~/.claude/CLAUDE.md):
#           output   growth
#   recon     5000     8000   Q&A, single-file read, orientation
#   change   10000    15000   scoped change or fix          <- default
#   feature  20000    25000   multi-file feature, plan, investigation
#   scene    20000    60000   Unity scene merge / conflict resolution (provisional)
#
# Two budgets because they are different failure modes. Output overruns mean the
# prompt bundled too much work; growth overruns mean too much material was pulled
# into the window - and growth is charged at the cache-write rate and re-charged
# on every later cache miss, so it is usually the dearer mistake.
#
# Overrides: TOKEN_BUDGET, TOKEN_ALERT_BUDGET, TOKEN_GROWTH_BUDGET,
#            TOKEN_ALERT_GROWTH, TOKEN_RESTART_THRESHOLD,
#            TOKEN_CONTEXT_WARN, TOKEN_CONTEXT_HIGH.
#
# History: --alert appends one raw row per cycle to token-history.csv. That write
# happens inside the hook, which already runs every cycle, so collecting it costs
# nothing in model tokens - only reading --stats does. Rows carry the measured
# quantities, never a bucket or a verdict, so retuning a threshold does not
# invalidate the history; --stats rescores whatever is already on disk.

set -u

PROJECTS="$HOME/.claude/projects"
ERRLOG="$HOME/.claude/token-alert-errors.log"
STATE="$HOME/.claude/token-occupancy.state"
HIST="$HOME/.claude/token-history.csv"
F=""
MODE="table"
ARG="${1:-}"

[ "$ARG" = "--alert" ] && MODE="alert"
[ "$ARG" = "--stats" ] && MODE="stats"
[ "$ARG" = "--retune" ] && MODE="retune"
[ "$ARG" = "--status" ] && MODE="status"

# Tier name -> output budget. A bare number passes through unchanged.
resolve_budget() {
  case "$1" in
    recon|read|qa|q)              echo 5000 ;;
    change|fix|edit|"")           echo 10000 ;;
    feature|plan|investigate|big) echo 20000 ;;
    scene|merge|unity)            echo 20000 ;;
    *[!0-9]*)                     echo 10000 ;;   # unrecognised word -> default
    *)                            echo "$1" ;;
  esac
}

# Tier name -> growth budget: how much NEW material a cycle of that class may
# pull into the window. Derived at n=44, not chosen: measured follow-on growth is
# median 8,149 / p80 17,846 / p90 21,443, and 25,000 is the lowest candidate that
# lands inside the 5-25% per-signal band (8%); 20,000 fires 19%, 12-15,000 fires
# 27% and is noise. A bare number passes through, but only when the arg is
# numeric - a tier word maps through the table above.
#
# `scene` is the one tier that is GUESSED, not derived: n=0 scene cycles measured
# so far, well under the n=40 the retune sweep needs. It exists because a Unity
# scene merge cannot be done cheaply - MainScene.unity is 23,000 lines of
# low-density YAML (~200k tokens to read whole), and resolving interleaved
# conflict hunks needs real surrounding context. Tag those cycles `scene`, let
# rows accumulate, then let --retune pick the real number.
#
# Deliberately a TIER and not a per-file exemption for *.unity. An exemption
# would forgive a careless full scene read during ordinary `change` work, which
# is the single most expensive mistake available in this repo; a tier has to be
# opted into per cycle, so the lazy path still trips the normal ceiling.
resolve_growth() {
  case "$1" in
    recon|read|qa|q)              echo 8000 ;;
    change|fix|edit|"")           echo 15000 ;;
    feature|plan|investigate|big) echo 25000 ;;
    scene|merge|unity)            echo 60000 ;;
    *[!0-9]*)                     echo 15000 ;;
    *)                            echo 25000 ;;   # explicit output number: growth stays at the loosest tier
  esac
}

if [ "$MODE" = "alert" ] || [ "$MODE" = "stats" ] || [ "$MODE" = "retune" ]; then
  # The hook can't know the task class, so it scores against the loosest tier.
  # Anything under that is somebody's legitimate feature cycle, not a breach.
  # --stats uses the same number so its rates describe the hook as it actually
  # runs, rather than a tier the hook never applies.
  BUDGET="${TOKEN_ALERT_BUDGET:-20000}"
  GROWTH="${TOKEN_ALERT_GROWTH:-25000}"
else
  BUDGET="${TOKEN_BUDGET:-$(resolve_budget "$ARG")}"
  GROWTH="${TOKEN_GROWTH_BUDGET:-$(resolve_growth "$ARG")}"
fi

RESTART="${TOKEN_RESTART_THRESHOLD:-60000}"

# Context occupancy bands. Unlike RESTART (a per-cycle delta) these measure the
# absolute size of the window every request re-reads, which is what actually
# scales cost across a long session.
# Retuned 2026-08-08 at n=40 (the n>=40 gate). Derived, not chosen: the weighted
# break-even is ~204,558 at the measured 4.4 cycles/session, and ~300k is where a
# restart still pays with only 3 cycles left. The old 100k/140k came from the raw
# unweighted model on a minimum-not-median floor and were 2-3x too low - 100k was
# firing on 31% of cycles, well outside the 5-25% band.
CTXWARN="${TOKEN_CONTEXT_WARN:-200000}"

# Statusline park hint. Not an alert band - it is the one signal that reaches
# the user BEFORE they step away, which is the only moment the gap cost is
# still avoidable, where the break-even is only ~62k - not the ~127k the gap
# hook uses, because that one speaks after the rewrite is already sunk. The two
# thresholds are meant to differ; 120k here is already the conservative side.
PARKAT="${TOKEN_PARK_HINT_CONTEXT:-120000}"
CTXHIGH="${TOKEN_CONTEXT_HIGH:-300000}"

# Re-derivation cost: the tokens a fresh session spends pulling back the material
# it needs to resume - notes, the files under discussion, the plan. Unlike the
# floor this is NOT measurable from the CSV (nothing distinguishes "re-reading to
# catch up" from "reading something new"), so it is a stated parameter, not an
# observation. Good notes are what make it small; it is the one term in the
# break-even you control directly.
REDERIVE="${TOKEN_REDERIVE_COST:-34000}"   # measured median 34,066, n=29 (2026-08-24); was an assumed 15,000

# Price weights, relative to an uncached input token. Source: the bundled
# claude-api skill; local copy in ~/.claude/pricing-reference.md. Raw token counts
# are not one currency - output costs 50x a cache read - so any total that adds
# them together is meaningless. Cache-write weight assumes the 1-hour TTL these
# sessions run on; set W_WRITE=1.25 for a 5-minute TTL.
W_OUT="${TOKEN_W_OUTPUT:-5}"
W_WRITE="${TOKEN_W_CACHE_WRITE:-2}"
W_READ="${TOKEN_W_CACHE_READ:-0.1}"

# Requests per cycle. Scales the weighted break-even linearly. Measured at 2.3 on
# one session (30 deduped requests / 13 cycles); the CSV does not record it, so
# like TOKEN_REDERIVE_COST this is a stated parameter, not a measurement.
REQS="${TOKEN_REQS_PER_CYCLE:-2.3}"

# Cold floor: context occupied at cycle 1, before a session has done any work of
# its own - system prompt, tool schemas, skill listings, CLAUDE.md, memory. It is
# what a restart re-pays up front. Measured from history when there is enough of
# it; the fallback is the observed value at the time of writing.
# Median, not minimum. The minimum makes one unusually small cold start the
# permanent basis of every break-even number: on 2026-08-07 the 60k row read
# N > 25.4 (floor 42,729) and on 2026-08-08 it read N > 3.8, a 6.7x swing from a
# single 32,567 sample with no change in behaviour. The median is what a restart
# actually lands on.
read_floor() {
  [ -f "$HIST" ] || { echo 43000; return; }
  m=$(awk -F, 'NR>1 && NF>=7 && $3+0==1 && $6+0>0 { print $6+0 }' "$HIST" 2>/dev/null \
      | sort -n \
      | awk '{v[NR]=$1}
             END { if (NR < 2) exit
                   print (NR%2) ? v[(NR+1)/2] : int((v[NR/2]+v[NR/2+1])/2) }')
  case "$m" in
    ''|*[!0-9]*) echo 43000 ;;
    *) [ "$m" -gt 0 ] && echo "$m" || echo 43000 ;;
  esac
}

# --- history report --------------------------------------------------------
# Reads only the CSV; needs no transcript and no session. Everything here is
# recomputed from raw columns, so the thresholds below are today's, not the
# ones that were in force when a row was written.

# --- threshold sweep -------------------------------------------------------
# Scores the whole history against candidate thresholds so a retune is one
# command instead of a run of manual env-var experiments. Suggests nothing and
# changes nothing: it prints what each candidate WOULD have fired at, and you
# pick. Rows are raw measurements, which is the only reason this rescoring is
# meaningful at all.

if [ "$MODE" = "retune" ]; then
  if [ ! -f "$HIST" ] || [ "$(wc -l < "$HIST")" -lt 2 ]; then
    echo "no history yet at $HIST" >&2
    exit 1
  fi
  awk -F, -v budget="$BUDGET" -v gbudget="$GROWTH" -v restart="$RESTART" -v ctxwarn="$CTXWARN" '
  function commify(n,   _s,_out,_len,_i,_rem) {
    _s = sprintf("%d", n); _out = ""; _len = length(_s)
    for (_i = 1; _i <= _len; _i++) {
      _out = _out substr(_s, _i, 1); _rem = _len - _i
      if (_rem > 0 && _rem % 3 == 0) _out = _out ","
    }
    return _out
  }
  # rows is the denominator for THIS signal, which is not always the row count:
  # growth only exists on follow-on cycles, so scoring it against n would report
  # a rate against a population it was never measured on.
  function sweep(label, col, cand, ncand, cur, ge, rows,   i, j, hits, rate, mark, band) {
    printf "\n  %s   (current %s, over %d cycles)\n", label, commify(cur), rows
    for (i = 1; i <= ncand; i++) {
      hits = 0
      for (j = 1; j <= rows; j++)
        if (ge ? v[col, j] >= cand[i] : v[col, j] > cand[i]) hits++
      rate = hits * 100 / rows
      # 5-25% is the per-signal band: below it the threshold teaches nothing,
      # above it the alert becomes noise you stop reading.
      band = (rate >= 5 && rate <= 25) ? "  <- in band" : ""
      mark = (cand[i] == cur) ? " *" : "  "
      printf "    %-9s%s %3d/%d  %5.0f%%%s\n", commify(cand[i]), mark, hits, rows, rate, band
    }
  }
  NR == 1 { next }
  NF < 7  { next }
  {
    n++; v["out", n] = $4 + 0; v["rc", n] = $5 + 0; v["ctx", n] = $6 + 0
    # Growth is not a stored column - it is the per-session context delta, so it
    # is reconstructed here. Keyed on the session id rather than the previous
    # row because sessions interleave in the file. Cycle 1 has no predecessor and
    # its growth is the cold load, so it is left out of the sweep entirely.
    if ($3 + 0 > 1 && ($2 in lastctx)) {
      gr = ($6 + 0) - lastctx[$2]; if (gr < 0) gr = 0
      gn++; v["gro", gn] = gr
    }
    lastctx[$2] = $6 + 0
  }
  END {
    if (n == 0) { print "history file has no usable rows" > "/dev/stderr"; exit 1 }
    printf "\n  threshold sweep over %d cycles   (* = current, no changes made)\n", n
    no = split("15000 20000 25000 30000 40000", oc, " ")
    ng = split("12000 15000 20000 25000 30000", gc, " ")
    nr = split("40000 60000 80000 100000 120000", rc, " ")
    # Spans the retuned bands; the old 80-160k list topped out below the current
    # 200k warn, so the "current" marker never appeared on its own sweep.
    nc = split("120000 160000 200000 250000 300000", cc, " ")
    sweep("TOKEN_ALERT_BUDGET      output >", "out", oc, no, budget, 0, n)
    if (gn >= 2)
      sweep("TOKEN_ALERT_GROWTH      growth >", "gro", gc, ng, gbudget, 0, gn)
    sweep("TOKEN_RESTART_THRESHOLD re-cache >", "rc", rc, nr, restart, 0, n)
    sweep("TOKEN_CONTEXT_WARN      context >=", "ctx", cc, nc, ctxwarn, 1, n)
    printf "\n  pick per signal, not for the union. Four signals in band individually\n"
    printf "  will read as ~45-60%% combined, which is expected and not a fault.\n"
    if (n < 40)
      printf "\n  WARNING: n=%d. Any pick here is fitting noise. Revisit at 40+.\n\n", n
    else
      printf "\n  export the chosen values, then re-run --stats to confirm.\n\n"
  }' "$HIST"
  exit 0
fi

if [ "$MODE" = "stats" ]; then
  if [ ! -f "$HIST" ] || [ "$(wc -l < "$HIST")" -lt 2 ]; then
    echo "no history yet at $HIST" >&2
    echo "it fills one row per cycle from the Stop hook; run a few cycles first" >&2
    exit 1
  fi
  awk -F, -v budget="$BUDGET" -v gbudget="$GROWTH" -v restart="$RESTART" \
      -v ctxwarn="$CTXWARN" -v ctxhigh="$CTXHIGH" -v rederive="$REDERIVE" \
      -v wwrite="$W_WRITE" -v wread="$W_READ" -v reqs="$REQS" \
      -v contgap="${TOKEN_CONTINUATION_GAP:-30}" '
  function commify(n,   _s,_out,_len,_i,_rem) {
    _s = sprintf("%d", n); _out = ""; _len = length(_s)
    for (_i = 1; _i <= _len; _i++) {
      _out = _out substr(_s, _i, 1); _rem = _len - _i
      if (_rem > 0 && _rem % 3 == 0) _out = _out ","
    }
    return _out
  }
  # Manual sort: mawk has no asort, and this file is small.
  function pct(arr, n, p,   _i,_j,_t,_k) {
    for (_i = 2; _i <= n; _i++) {
      _t = arr[_i]
      for (_j = _i - 1; _j >= 1 && arr[_j] > _t; _j--) arr[_j+1] = arr[_j]
      arr[_j+1] = _t
    }
    _k = int(p * n + 0.5); if (_k < 1) _k = 1; if (_k > n) _k = n
    return arr[_k]
  }
  # Minutes since an arbitrary epoch, for gap detection only. Month lengths are
  # approximated at 31 days, which is wrong across a month boundary but never by
  # enough to matter for a threshold measured in minutes.
  function tomin(s,   p,a,b) {
    split(s, p, " "); split(p[1], a, "-"); split(p[2], b, ":")
    return ((a[1] * 12 + a[2]) * 31 + a[3]) * 1440 + b[1] * 60 + b[2]
  }
  NR == 1 { next }                      # header
  NF < 7  { next }                      # partial line from a torn write
  {
    n++
    sess[$2] = 1
    out[n] = $4 + 0
    if (first == "") first = $1
    last = $1
    if ($4 + 0 > budget)   fo++
    if ($5 + 0 > restart)  fr++
    if ($6 + 0 >= ctxwarn) fc++
    if ($7 != "" && $7 != "-") fired++   # what the hook actually said at the time
    # Cycle 1 is the cold floor: what the window already holds before the session
    # has done anything. Collected separately because it sets the price of a
    # restart, which no other column captures.
    if ($3 + 0 == 1) {
      # A session opening within contgap minutes of the previous recorded cycle
      # is almost certainly resuming the same work, so what it holds above what
      # a FRESH session holds is re-derivation. Crude, but it is the only signal
      # in the data that separates catching up from starting something new.
      #
      # The two populations are kept apart deliberately. Pooling them put every
      # resumed session into the floor as well, which pushed the floor up and
      # then measured re-derivation above the pushed-up number - the term ended
      # up in both halves of the same subtraction.
      if (prevts != "" && tomin($1) - tomin(prevts) <= contgap) { rd++; contctx[rd] = $6 + 0 }
      else { cs++; cold[cs] = $6 + 0 }
    }
    # Re-cache splits into growth (new material pulled in this cycle, which is
    # the part you choose) and churn (context that was already there being
    # rewritten on a cache miss, which you can only avoid by ending the session).
    # Judging a cycle on the raw re-cache number confuses the two.
    if ($3 + 0 > 1 && ($2 in lastctx)) {
      g = ($6 + 0) - lastctx[$2]; if (g < 0) g = 0
      ch = ($5 + 0) - g;          if (ch < 0) ch = 0
      gn++; growth[gn] = g; churn[gn] = ch; sumG += g; sumC += ch
      if (g > gbudget) fg++
    }
    lastctx[$2] = $6 + 0
    prevts = $1
    sumOut += $4 + 0
  }
  END {
    if (n == 0) { print "history file has no usable rows" > "/dev/stderr"; exit 1 }
    ns = 0; for (k in sess) ns++
    printf "\n"
    printf "  %s cycles across %d sessions\n", commify(n), ns
    printf "  %s  ->  %s\n", first, last
    printf "\n"
    printf "  hook fired on %d of %s cycles  (%.0f%%)\n", fired + 0, commify(n), (fired + 0) * 100 / n
    printf "\n"
    printf "  rescored at the current thresholds:\n"
    printf "    output   > %-8s %5d cycles  (%.0f%%)\n", commify(budget),  fo + 0, (fo + 0) * 100 / n
    # Denominator is gn, not n: growth is only defined on follow-on cycles.
    if (gn > 0)
      printf "    growth   > %-8s %5d cycles  (%.0f%%  of %d follow-on)\n", \
        commify(gbudget), fg + 0, (fg + 0) * 100 / gn, gn
    printf "    re-cache > %-8s %5d cycles  (%.0f%%)\n", commify(restart), fr + 0, (fr + 0) * 100 / n
    printf "    context >= %-7s %5d cycles  (%.0f%%)\n", commify(ctxwarn), fc + 0, (fc + 0) * 100 / n
    printf "\n"
    printf "  output per cycle: median %s   p90 %s   max %s   mean %s\n", \
      commify(pct(out, n, 0.50)), commify(pct(out, n, 0.90)), \
      commify(pct(out, n, 1.00)), commify(sumOut / n)
    printf "  cycles per session: %.1f\n", n / ns
    printf "\n"

    # --- where the re-cache actually goes ----------------------------------
    if (gn >= 2) {
      printf "  re-cache split over %d follow-on cycles:\n", gn
      printf "    growth (new material)   median %s   total %s\n", \
        commify(pct(growth, gn, 0.50)), commify(sumG)
      printf "    churn  (window rewrite) median %s   total %s   %.0f%% of re-cache\n", \
        commify(pct(churn, gn, 0.50)), commify(sumC), \
        (sumG + sumC > 0) ? sumC * 100 / (sumG + sumC) : 0
      printf "  growth is the half you choose; churn is the price of session length.\n"
      printf "\n"
    }

    # --- restart economics -------------------------------------------------
    # A fresh session is not free: it re-pays the floor plus whatever it takes to
    # get back up to speed. Both sides are price-weighted below - carrying costs
    # cache READS (0.1x) per request, restarting costs a cache WRITE (2x) of the
    # floor plus re-derivation, once. Comparing them as raw tokens overstated the
    # case for restarting by roughly an order of magnitude.
    if (cs >= 2) {
      rdu = rederive
      f = pct(cold, cs, 0.00)
      fmed = pct(cold, cs, 0.50)
      printf "  cold floor (context at cycle 1, %d fresh starts): min %s   median %s\n", \
        cs, commify(f), commify(fmed)
      # Measured re-derivation, when there is anything to measure it from. This
      # is the term the break-even is most sensitive to and the one that was
      # pure assumption until now, so show the observation next to the assumption
      # rather than silently swapping one for the other.
      if (rd >= 2) {
        # Against the MEDIAN fresh start, not the minimum one. Both sides have
        # to be the same statistic, or the distance from the minimum to the
        # median gets counted twice - which inflated this figure roughly
        # threefold, and every band derived from it with it.
        for (i = 1; i <= rd; i++) { rdv[i] = contctx[i] - fmed; if (rdv[i] < 0) rdv[i] = 0 }
        # Below n=5 a median is barely distinguishable from a single sample, and
        # this term swings the break-even hard - so show the spread instead of a
        # centre that looks more settled than it is.
        if (rd < 5)
          printf "  re-derivation: assumed %s  |  observed %s - %s across %d resumed sessions\n    (n=%d, spread not a median - do not move TOKEN_REDERIVE_COST on this)\n", \
            commify(rederive), commify(pct(rdv, rd, 0.00)), commify(pct(rdv, rd, 1.00)), rd, rd
        else {
          # Past this many samples the measurement is better than the guess, so
          # the table below uses it. Printed either way: a threshold that
          # silently changes what the advice is built on is worse than a stale
          # constant, because nothing on screen says which one is in play.
          rdu = pct(rdv, rd, 0.50)
          printf "  re-derivation: assumed %s  |  measured median %s over %d resumed sessions\n    (the table below now uses the measured one)\n", \
            commify(rederive), commify(rdu), rd }
      } else {
        printf "  re-derivation cost assumed: %s  (TOKEN_REDERIVE_COST; too few resumed\n    sessions to measure - need 2+, have %d)\n", commify(rederive), rd + 0
      }
      printf "\n"
      # Weighted, and on the median floor. Two corrections to the raw model:
      #   - the basis is the median cold start, not the minimum. One low sample
      #     used to move every row here by several multiples.
      #   - the savings are cache READS (0.1x) while the restart cost is a fresh
      #     cache WRITE of the floor (2x). Comparing them as raw tokens overstated
      #     the case for restarting by roughly an order of magnitude.
      # carry/cycle = dC * reqs * wread ; restart = (floor + rederive) * wwrite
      printf "  restart pays off after N more cycles of work:\n"
      printf "    (weighted: savings are cache reads x%s, restart is a cache write x%s,\n", wread, wwrite
      printf "     at an assumed %s requests per cycle)\n", reqs
      for (i = 1; i <= 4; i++) {
        c = (i == 1 ? 60000 : i == 2 ? ctxwarn : i == 3 ? 120000 : ctxhigh)
        save = (c - fmed - rdu) * reqs * wread
        cost = (fmed + rdu) * wwrite
        if (save <= 0)
          printf "    at %-8s  never - a fresh session would sit no lower\n", commify(c)
        else
          printf "    at %-8s  N > %.1f   (saves %s/cycle, costs %s once)\n", \
            commify(c), cost / save, commify(save), commify(cost)
      }
      # Where the band should sit for a session of typical length here.
      if (ns > 0 && n > 0) {
        cps = n / ns
        be = (fmed + rdu) * wwrite / (cps * reqs * wread) + fmed + rdu
        printf "    -> at %.1f cycles/session, the break-even context is ~%s\n", cps, commify(be)
      }
      printf "\n"
      printf "  lowering the floor helps every session; lowering re-derivation (better\n"
      printf "  notes) makes restarts pay off sooner. Raising the bands does neither.\n"
    } else {
      printf "  cold floor: need cycle-1 rows from 2+ sessions; have %d\n", cs + 0
    }
    printf "\n"

    if (n >= 40)
      printf "  history is large enough to retune (n=%d). Try TOKEN_ALERT_BUDGET /\n    TOKEN_CONTEXT_WARN variants and re-run; rows are raw, so they rescore.\n\n", n
    else
      printf "  n=%d is too small to retune on - a change now fits noise. Revisit at 40.\n\n", n

    printf "  the union rate above counts a cycle once if ANY signal fired, so it runs\n"
    printf "  higher than the per-signal rates beneath it. Judge each signal against\n"
    printf "  5-25%%; judge the union against ~45-60%% with four signals live.\n"
    printf "\n"
  }' "$HIST"
  exit 0
fi

# --- locate the transcript -------------------------------------------------

if [ "$MODE" = "alert" ]; then
  # Stop hooks receive their payload as JSON on stdin. Windows paths arrive
  # JSON-escaped (C:\\Users\\...); backslash -> slash is enough for Git Bash,
  # and doubled slashes in the middle of a path are harmless.
  payload=$(cat 2>/dev/null || true)
  tp=$(printf '%s' "$payload" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr '\\' '/')
  [ -n "$tp" ] && [ -f "$tp" ] && F="$tp"
fi

# Exact session match — this is what makes the numbers right when several
# sessions are open at once.
if [ -z "$F" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  F=$(find "$PROJECTS" -name "$CLAUDE_CODE_SESSION_ID.jsonl" 2>/dev/null | head -1)
fi

# Fallback for running outside a session, or on a CLI that doesn't set the var.
if [ -z "$F" ] && [ "$MODE" != "alert" ]; then
  F=$(ls -t "$PROJECTS"/*/*.jsonl 2>/dev/null | head -1)
  [ -n "$F" ] && echo "note: no session id; using newest transcript ($(basename "$F"))" >&2
fi

if [ -z "$F" ] || [ ! -f "$F" ]; then
  # A hook that silently finds nothing looks identical to a hook that found no
  # breach, so record it somewhere checkable rather than dying quietly.
  if [ "$MODE" = "alert" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') no transcript resolved from hook payload" >> "$ERRLOG" 2>/dev/null
    exit 0
  fi
  echo "no transcript found under $PROJECTS" >&2
  exit 1
fi

# The occupancy alert latches per session so it fires once per band crossing
# instead of every cycle once you are over. Keyed by session id, not path.
SESSION_KEY=$(basename "$F" .jsonl)

# Cache TTL countdown for the status line. The prompt cache lives one hour, and a
# resume after it expires rewrites the whole window at the 2x write rate - the
# single largest line in this repo's bill (26% of weighted cost). The Stop hook
# already stamps every cycle, so the remaining life is arithmetic. Showing it is
# what turns the park/clear decision from a guess into a lookup: you can see
# whether the gap already happened instead of estimating it.
# Other sessions about to lapse. The status line cannot see them and they are
# where the money goes: 59% of gap-rewrites had another of the user's sessions
# active during the idle window. Recency in the CSV stands in for liveness here
# - a real process check means a tasklist dump, far too heavy for something that
# redraws on every keystroke. Only sessions inside the last hour with <=15m left
# are shown, because that is the only window where acting still helps.
OTHERS=""
if [ "$MODE" = "status" ] && [ -f "$HIST" ]; then
  OTHERS=$(awk -F, -v me="$(printf '%s' "$SESSION_KEY" | cut -c1-8)" \
               -v ttl="${TOKEN_CACHE_TTL_MIN:-60}" -v warn="${TOKEN_OTHERS_WARN_MIN:-15}" \
               -v now="$(date '+%Y %m %d %H %M %S')" '
    function tomin(s) { gsub("-", " ", s); gsub(":", " ", s); return mktime(s " 00") / 60 }
    NR > 1 && $2 != me { last[$2] = $1; ctx[$2] = $6 }
    END {
      n = 0
      for (k in last) {
        left = ttl - (mktime(now) / 60 - tomin(last[k]))
        if (left > 0 && left <= warn && ctx[k] + 0 >= 60000) {
          out = out sprintf(" %s %dm", substr(k, 1, 4), left); if (++n >= 2) break
        }
      }
      if (n > 0) printf "  |%s", out
    }' "$HIST" 2>/dev/null)
fi

CACHE_LEFT=""
if [ "$MODE" = "status" ] && [ -f "$HIST" ]; then
  CACHE_LEFT=$(awk -F, -v k="$(printf '%s' "$SESSION_KEY" | cut -c1-8)" \
                   -v ttl="${TOKEN_CACHE_TTL_MIN:-60}" \
                   -v now="$(date '+%Y %m %d %H %M %S')" '
    function tomin(s) { gsub("-", " ", s); gsub(":", " ", s); return mktime(s " 00") / 60 }
    $2 == k { last = $1 }
    END { if (last == "") exit; printf "%d\n", ttl - (mktime(now) / 60 - tomin(last)) }
  ' "$HIST" 2>/dev/null)
fi

# --- tally -----------------------------------------------------------------

# Header once, so the CSV is readable by anything that expects one.
if [ "$MODE" = "alert" ] && [ ! -f "$HIST" ]; then
  echo "ts,session,cycle,output,recache,context,fired" > "$HIST" 2>/dev/null || true
fi

FLOOR=$(read_floor)

# Retune prompt. Deliberately does NOT change any threshold on its own - a
# threshold that moves by itself makes every earlier row mean something
# different, and the drift is invisible afterwards. This only says "there is
# enough history now, go look", and latches so it says it once per batch of
# TOKEN_RETUNE_AT rows rather than every cycle forever.
RETUNE=""
RETUNE_AT="${TOKEN_RETUNE_AT:-40}"
RETUNE_MARK="$HOME/.claude/token-retune.state"
if [ "$MODE" = "alert" ] && [ -f "$HIST" ]; then
  rows=$(( $(wc -l < "$HIST" 2>/dev/null || echo 1) - 1 ))
  last=0
  [ -f "$RETUNE_MARK" ] && last=$(cat "$RETUNE_MARK" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$rows" -ge "$RETUNE_AT" ] && [ "$rows" -ge "$(( last + RETUNE_AT ))" ]; then
    RETUNE="history has reached $rows cycles - run token-cycles.sh --stats and rescore the bands before they drift"
    echo "$rows" > "$RETUNE_MARK" 2>/dev/null || true
  fi
fi

awk -v budget="$BUDGET" -v gbudget="$GROWTH" -v restart="$RESTART" -v mode="$MODE" \
    -v floor="$FLOOR" -v rederive="$REDERIVE" -v retune="$RETUNE" \
    -v wout="$W_OUT" -v wwrite="$W_WRITE" -v wread="$W_READ" -v reqs="$REQS" \
    -v ctxwarn="$CTXWARN" -v ctxhigh="$CTXHIGH" -v parkat="$PARKAT" \
    -v cacheleft="$CACHE_LEFT" -v parkctx="${TOKEN_PARK_CROSSOVER:-80000}" \
    -v others="$OTHERS" \
    -v state="$STATE" -v statekey="$SESSION_KEY" \
    -v hist="$HIST" -v now="$(date '+%Y-%m-%d %H:%M')" '
function commify(n,   _s, _out, _len, _i, _rem) {
  _s = sprintf("%d", n); _out = ""; _len = length(_s)
  for (_i = 1; _i <= _len; _i++) {
    _out = _out substr(_s, _i, 1)
    _rem = _len - _i
    if (_rem > 0 && _rem % 3 == 0) _out = _out ","
  }
  return _out
}

function bar(v, maxv, width,   _k, _j, _b) {
  if (maxv <= 0) return ""
  _k = int((v / maxv) * width + 0.5)
  if (_k > width) _k = width
  _b = ""
  for (_j = 0; _j < _k; _j++) _b = _b "#"
  return _b
}

# Compact form for the status line, where width is scarce.
function kfmt(v) {
  v = v + 0
  if (v >= 1000) return sprintf("%.1fk", v / 1000)
  return sprintf("%d", v)
}

# promptId tags only user lines and repeats across every line of a cycle, so a
# new cycle is a *change* in the value, not its presence.
/"type":"user"/ && match($0, /"promptId":"[a-f0-9-]+"/) {
  pid = substr($0, RSTART, RLENGTH)
  if (pid != last) { cycle++; last = pid }
  next
}

# The same usage object is written ~2.5x per message; dedupe by message id or
# the totals overcount badly.
/"output_tokens"/ && !/"isSidechain":true/ {
  key = (match($0, /msg_[A-Za-z0-9]+/)) ? substr($0, RSTART, RLENGTH) : "L" NR
  if (key in seen) next
  seen[key] = 1
  _o = _cc = _cr = _it = 0
  if (match($0, /"output_tokens":[0-9]+/))               { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); _o=s+0 }
  if (match($0, /"cache_creation_input_tokens":[0-9]+/)) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); _cc=s+0 }
  if (match($0, /"cache_read_input_tokens":[0-9]+/))     { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); _cr=s+0 }
  # Anchored on { or , because "input_tokens": is also a *substring* of both
  # cache_creation_input_tokens and cache_read_input_tokens.
  if (match($0, /[{,]"input_tokens":[0-9]+/))            { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); _it=s+0 }
  o[cycle] += _o
  c[cycle] += _cc
  # Summed, not assigned: every request in the cycle pays its own cache read, so
  # the read cost for a cycle is the total across requests, not the last one.
  q[cycle] += _cr
  # Prompt size for this request = cached prefix + newly cached + uncached tail.
  # Assigned (not accumulated) so the last message of a cycle wins, which is
  # occupancy at the end of that cycle. Last, never max: compaction drops it.
  _ctx = _cr + _cc + _it
  if (_ctx > 0) { r[cycle] = _ctx; occ = _ctx }
}

END {
  if (cycle == 0) {
    if (mode != "alert") print "no completed cycles yet"
    exit
  }

  # Interrupted cycles produce no assistant message at all, leaving these array
  # slots unset; coerce to numbers before they reach any function.
  for (i = 1; i <= cycle; i++) {
    ov = o[i] + 0; cv = c[i] + 0
    o[i] = ov; c[i] = cv; r[i] = r[i] + 0; q[i] = q[i] + 0
    outTotal += ov; newTotal += cv; readTotal += q[i]
    if (cv > maxNew) maxNew = cv
    if (ov > budget) over++
    # Growth is what entered the window this cycle - the half you choose. It is
    # the context delta; whatever re-cache is left over is churn, which you can
    # only avoid by ending the session. On cycle 1 it is the cold load.
    g[i] = (i == 1) ? r[i] : r[i] - r[i-1]
    if (g[i] < 0) g[i] = 0
    if (i > 1) { growTotal += g[i]; if (g[i] > maxGrow) maxGrow = g[i] }
    ch = cv - g[i]; if (ch < 0) ch = 0
    churnTotal += ch
  }
  occ = occ + 0

  band = 0
  if (occ >= ctxwarn) band = 1
  if (occ >= ctxhigh) band = 2

  # Stop-hook mode: silent on a clean cycle, one line on a breach. The last
  # assistant message may still be mid-write, so treat this as a floor.
  if (mode == "alert") {
    ov = o[cycle]; cv = c[cycle]; gv = g[cycle]
    msg = ""
    if (ov > budget)
      msg = "cycle " cycle " produced " commify(ov) " output tokens vs a " commify(budget) " ceiling - the prompt probably bundled discovery, design and implementation"
    # Growth is the other half of the bill and the half nothing used to watch.
    # Cycle 1 is exempt: its "growth" is the cold load, which no prompt chose.
    if (cycle > 1 && gv > gbudget) {
      gm = "cycle " cycle " pulled " commify(gv) " tokens of new material into the window vs a " commify(gbudget) " ceiling - charged at the cache-write rate and re-charged on every later miss, so name the heavy load and why the cheaper path would not do"
      msg = (msg == "") ? gm : msg "; " gm
    }
    if (cv > restart) {
      # Split the re-cache before advising anything: the same number means two
      # different mistakes, and only one of them is a reason to end the session.
      chv = cv - gv; if (chv < 0) chv = 0
      if (cycle == 1)
        # Nothing to attribute yet - on cycle 1 the whole window is the cold
        # load, so calling it "growth" would blame the prompt for the floor.
        rc = "context re-cached " commify(cv) " tokens on the opening cycle - that is the cold load, not something this prompt chose"
      else
        rc = "context re-cached " commify(cv) " tokens this cycle (" commify(gv) " growth, " commify(chv) " churn) - " \
             (gv >= chv ? "that is mostly new material, so it is what entered the window, not the session length" \
                        : "that is mostly the window being rewritten, which only ends when the session does")
      msg = (msg == "") ? rc : msg "; " rc
    }

    # Read the latched band for this session, keeping the lines for every other
    # session so the rewrite below does not drop them. Third field is the last
    # cycle recorded to history; older two-field lines read back as 0, which is
    # correct for a session that predates the history file.
    lastband = 0; lastcycle = 0; nk = 0
    while ((getline line < state) > 0) {
      split(line, a, " ")
      if (a[1] == statekey) { lastband = a[2] + 0; lastcycle = a[3] + 0 }
      else if (line != "")  keep[++nk] = line
    }
    close(state)

    # Fire on a *crossing* only. Without this it repeats every cycle once you
    # are over and stops being read.
    if (band > lastband) {
      # Occupancy is mostly a QUALITY signal, not a cost one. Re-reading the
      # window is charged at the cache-read rate (0.1x) and measured at ~13% of
      # session cost, so "restart to save money" is usually false at these sizes.
      # The real reasons to cut are attention dilution, compaction risk, and the
      # hard window limit. The cost line is still printed, weighted and honest,
      # so the two arguments are not confused for each other.
      save = (occ - floor - rederive) * reqs * wread
      cost = (floor + rederive) * wwrite
      cm = "context window is at " commify(occ) " tokens - the reason to cut is attention dilution, compaction risk and headroom, not cost"
      if (save <= 0)
        cm = cm "; a fresh session would sit near " commify(floor + rederive) ", so it saves nothing either"
      else
        cm = cm sprintf("; on cost alone a restart pays only with more than %.0f cycles left (saves %s/cycle weighted, costs %s once)", \
                        cost / save, commify(save), commify(cost))
      msg = (msg == "") ? cm : msg "; " cm
    }

    # Independent of any breach - the prompt to retune has to reach you on a
    # clean cycle too, or it waits for an alert that may never come.
    if (retune != "") msg = (msg == "") ? retune : msg "; " retune

    # One row per cycle. Guarded on the cycle number because a Stop hook that
    # fires twice for the same cycle would otherwise inflate every rate in
    # --stats, and a doubled denominator is not something you can spot later.
    if (hist != "" && cycle > lastcycle) {
      fired = ""
      if (ov > budget)    fired = fired "o"
      if (cycle > 1 && gv > gbudget) fired = fired "g"
      if (cv > restart)   fired = fired "r"
      if (band > lastband) fired = fired "c"
      if (fired == "") fired = "-"
      printf "%s,%s,%d,%d,%d,%d,%s\n", now, substr(statekey, 1, 8), cycle, ov, cv, occ, fired >> hist
      close(hist)
    }

    if (band != lastband || cycle != lastcycle) {
      for (i = 1; i <= nk; i++) print keep[i] > state
      print statekey " " band " " cycle > state
      close(state)
    }

    if (msg != "") printf "{\"systemMessage\": \"token budget: %s\"}\n", msg
    exit
  }

  # Status-line mode: one short line, facts only, no judgement. Runs on every
  # status refresh, so it must stay cheap and must never print anything a
  # terminal has to wrap.
  if (mode == "status") {
    gLast = (cycle > 1) ? r[cycle] - r[cycle-1] : r[cycle]
    if (gLast < 0) gLast = 0
    mark = (occ >= ctxhigh) ? "!" : ((occ >= ctxwarn) ? "*" : "")

    # Cache life. Blank on the first cycle of a session (nothing to measure
    # from). Once it reads COLD the rewrite is already sunk, which is exactly
    # when clearing is cheapest - so say so rather than staying quiet.
    cache = ""
    if (cacheleft != "")
      cache = (cacheleft + 0 > 0) ? sprintf("  cache %dm", cacheleft + 0) : "  cache COLD"

    # The park hint fires on context alone at parkat, but the moment that
    # actually matters is a warm cache about to lapse on a window worth saving:
    # 80k is where park+clear (~159k) undercuts carrying one gap (context x 2).
    expiring = (cacheleft != "" && cacheleft + 0 > 0 && cacheleft + 0 <= 10 && occ >= parkctx)
    park = (occ >= parkat || expiring) ? "  /park" : ""
    printf "ctx %s%s  grew +%s  out %s  c%d%s%s%s\n", \
      kfmt(occ), mark, kfmt(gLast), kfmt(o[cycle]), cycle, cache, park, others
    exit
  }

  printf "\n"
  printf "  %-5s %9s  %-22s %10s  %-15s %10s\n", "cycle", "output", "work (budget " commify(budget) ")", "growth", "growth (bud " commify(gbudget) ")", "context"
  printf "  %-5s %9s  %-22s %10s  %-15s %10s\n", "-----", "--------", "----------------------", "----------", "---------------", "----------"

  for (i = 1; i <= cycle; i++) {
    workBar = bar(o[i], budget, 20)
    if (o[i] > budget) workBar = workBar ">>"
    # Growth on cycle 1 is the cold load, which no prompt chose - it is reported
    # but never scored, or every session would open on a breach.
    if (i == 1) { growBar = "(cold load)" }
    else {
      growBar = bar(g[i], gbudget, 13)
      if (g[i] > gbudget) { growBar = growBar ">>"; gover++ }
    }
    printf "  %-5d %9s  %-22s %10s  %-15s %10s\n", i, commify(o[i]), workBar, commify(g[i]), growBar, commify(r[i])
  }

  # Weighted totals. Raw counts are not comparable across classes - output costs
  # 50x a cache read - so the only honest single number is price-weighted.
  wo = outTotal * wout; ww = newTotal * wwrite; wr = readTotal * wread
  wtot = wo + ww + wr
  printf "\n"
  printf "  %d cycles   avg %s output   %d over the output budget   %d over the growth budget\n", \
    cycle, commify(outTotal / cycle), over + 0, gover + 0
  printf "  growth %s (yours to control)   churn %s (price of session length)\n", commify(growTotal), commify(churnTotal)
  if (wtot > 0) {
    printf "\n  cost-weighted (output x%s, cache-write x%s, cache-read x%s):\n", wout, wwrite, wread
    printf "    output      %11s  ->  %11s   %2.0f%%\n", commify(outTotal),  commify(wo), 100*wo/wtot
    printf "    cache write %11s  ->  %11s   %2.0f%%\n", commify(newTotal),  commify(ww), 100*ww/wtot
    printf "    cache read  %11s  ->  %11s   %2.0f%%\n", commify(readTotal), commify(wr), 100*wr/wtot
    printf "    total input-equivalents %s\n", commify(wtot)
  }
  printf "\n"
  printf "  context now %s  (warn %s / high %s)\n", commify(occ), commify(ctxwarn), commify(ctxhigh)
  if (maxNew > restart) printf "  peak re-cache %s is past the %s restart threshold\n", commify(maxNew), commify(restart)
  if (band == 2) printf "  context is past the high band - cut a session now\n"
  else if (band == 1) printf "  context is past the warn band - cut a session at the next subject change\n"
  printf "\n"
  printf "  work bar    = output vs the %s budget; \">>\" means over\n", commify(budget)
  printf "  growth      = what entered the window this cycle (the context delta).\n"
  printf "                This is the number you control, and it is charged at the\n"
  printf "                cache-write rate and re-charged on every later cache miss.\n"
  printf "  growth bar  = growth vs the %s budget for this tier; \">>\" means over.\n", commify(gbudget)
  printf "                Cycle 1 is the cold load and is never scored.\n"
  printf "  context     = window occupancy at the end of that cycle; every later\n"
  printf "                request re-reads it, but only at the cache-read rate,\n"
  printf "                so it is usually the cheapest line above\n"
  printf "  a big growth number is a choice - a heavy skill, a full file read,\n"
  printf "  a large command dump; churn is the price of session length\n"
  printf "  rescore with: /tokens recon | /tokens change | /tokens feature\n"
  printf "\n"
}' "$F"
