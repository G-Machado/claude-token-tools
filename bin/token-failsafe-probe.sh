#!/usr/bin/env bash
# Does a fork ping actually READ the prompt cache, or does it rebuild it?
#
# This is the question the fail-safe rests on and has never had a controlled
# answer. In the wild it was only ever measured once, against a VS Code parent,
# and it missed - but that run confounded two things: whether `--fork-session
# --resume` preserves a cache entry at all, and whether a print-mode fork can
# reach an INTERACTIVE session's prefix. Those need separating before deciding
# whether the feature is broken or merely mis-scoped.
#
# So this probe builds its own parent in print mode and forks that. Same-mode,
# same cwd, same flags - every variable held still except the fork itself:
#
#   leg 1  create a parent          -> expect a full cache WRITE (nothing to read)
#   leg 2  fork-resume that parent  -> the whole question. READ or WRITE?
#
#   leg 2 reads   the fork machinery works; the wild miss was the IDE prefix,
#                 so the fail-safe is mis-scoped, not broken
#   leg 2 writes  the fork can never hold anything open and the pinger should go
#
# Cheapest form that still answers it: Haiku (the mechanism is model-independent,
# the price is not), no MCP servers, a scratch cwd so no project CLAUDE.md loads,
# one turn, no tools, and a reply of one word.
#
# Footprint: both transcripts are deleted and both session ids are appended to
# token-failsafe-forks.txt, so the Stop-hook rows they leave stay out of the
# medians and grades the sessions tool computes. Deleting this file removes the
# probe entirely.
set -u
CL="$HOME/.claude"
FSFORKS="$CL/token-failsafe-forks.txt"
OUT="$CL/token-failsafe-probe.log"          # fresh every run, never appended
MODEL="${TOKEN_PROBE_MODEL:-claude-haiku-4-5-20251001}"
PROMPT='Reply with exactly: OK'

command -v claude >/dev/null 2>&1 || { printf 'no claude on PATH\n' >&2; exit 1; }

DIR=$(mktemp -d 2>/dev/null) || { printf 'no temp dir\n' >&2; exit 1; }
cd "$DIR" || exit 1
: > "$OUT"

log() { printf '%s\n' "$*" | tee -a "$OUT"; }

# Raw numbers only. Bucketing and verdicts happen at the bottom, off the
# collected values, so a wrong call here can be re-argued without re-running.
usage_of() {
  printf '%s' "$1" | grep -o '"cache_creation_input_tokens":[0-9]*' | head -1 | sed 's/.*://'
}
read_of() {
  printf '%s' "$1" | grep -o '"cache_read_input_tokens":[0-9]*' | head -1 | sed 's/.*://'
}
sid_of() {
  printf '%s' "$1" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# The prompt goes in on stdin, not as an argument. --disallowedTools is variadic
# (<tools...>), so a trailing prompt argument is swallowed as another tool name
# and the CLI then complains there was no prompt at all - which reads exactly
# like a broken probe rather than a misplaced word.
run() {  # run <extra-args...>
  printf '%s' "$PROMPT" | claude -p --output-format json --max-turns 1 \
    --model "$MODEL" --strict-mcp-config --disallowedTools 'Bash' "$@" 2>/dev/null
}

log "fail-safe fork probe   $(date '+%Y-%m-%d %H:%M:%S')"
log "model $MODEL   cwd $DIR"
log ""

log "leg 1  creating a parent session..."
O1=$(run)
S1=$(sid_of "$O1"); C1=$(usage_of "$O1"); R1=$(read_of "$O1")
if [ -z "$S1" ] || [ -z "${C1:-}" ]; then
  log "FAILED: leg 1 returned no usage. The probe measured nothing."
  log "raw: ${O1:0:400}"
  exit 2
fi
log "       session ${S1:0:8}   cache_creation ${C1}   cache_read ${R1:-0}"

# Two ways to re-enter a session, and the whole question is whether they differ.
#
#   fork   --fork-session --resume : mints a NEW session id. Safe against a live
#          session, because the original .jsonl is never opened for writing.
#   plain  --resume alone          : keeps the session id and APPENDS to that
#          session's transcript.
#
# The ~13k constant is why this matters. Both measured runs recovered the same
# fixed head no matter how big the parent was, which is what you would see if the
# conversation-level cache segment were keyed to the session id - and forking is
# precisely what throws that id away. If so, plain resume should recover the lot.
# Against a throwaway parent, plain is risk-free; against a live one it is two
# writers on one .jsonl, which is a separate problem to solve only if this wins.
MODE="${1:-plain}"
case "$MODE" in
  fork)  ARGS="--fork-session --resume $S1"; log "leg 2  forking it (new session id)..." ;;
  plain) ARGS="--resume $S1";                log "leg 2  resuming it (same session id)..." ;;
  *)     log "usage: token-failsafe-probe.sh [plain|fork]"; exit 2 ;;
esac
TF1=$(ls -1 "$CL"/projects/*/"$S1".jsonl 2>/dev/null | head -1)
SZ1=0; N1=0
if [ -n "$TF1" ]; then SZ1=$(wc -c < "$TF1"); N1=$(wc -l < "$TF1"); fi
# shellcheck disable=SC2086
O2=$(run $ARGS)
SZ2=0; N2=0
if [ -n "$TF1" ] && [ -f "$TF1" ]; then SZ2=$(wc -c < "$TF1"); N2=$(wc -l < "$TF1"); fi
S2=$(sid_of "$O2"); C2=$(usage_of "$O2"); R2=$(read_of "$O2")
if [ -z "${C2:-}" ] && [ -z "${R2:-}" ]; then
  log "FAILED: leg 2 returned no usage. The probe measured nothing."
  log "raw: ${O2:0:400}"
  exit 2
fi
log "       session ${S2:0:8}   cache_creation ${C2:-0}   cache_read ${R2:-0}"
log "       transcript ${N1} -> ${N2} records, ${SZ1} -> ${SZ2} bytes (+$(( SZ2 - SZ1 )))"
log ""

# NOT failsafe_reap's cr > cc test. That one asks "did more come from cache than
# went into it", which a small parent passes for the wrong reason: the fork adds
# a turn, so it always writes a fresh incremental block, and against a tiny
# window that block is smaller than the head it read. Passing there says nothing
# about whether the WINDOW was held.
#
# The question the fail-safe actually needs answered is how much of the PARENT
# came back. A fork that recovers a fixed head and rebuilds everything below it
# scales exactly the wrong way: harmless on the small windows nobody needs held,
# ruinous on the large ones that are the entire point.
PW=$(( ${C1:-0} + ${R1:-0} ))
PCT=0; [ "$PW" -gt 0 ] && PCT=$(( ${R2:-0} * 100 / PW ))
log "         parent window ${PW}, fork recovered ${R2:-0} of it (${PCT}%)"
if [ "$PCT" -ge 80 ]; then
  log "VERDICT  HOLDS - the fork recovered the parent's window."
  log "         The mechanism works; the wild miss was the IDE prefix. Scope the"
  log "         fail-safe to non-IDE parents rather than retire it."
else
  log "VERDICT  PARTIAL - the fork recovered only ${PCT}% of the parent."
  log "         It reads the cached head and rebuilds everything after it, so the"
  log "         rebuild grows with the window while the saving does not. On the"
  log "         large windows this exists to protect that is a full-price rewrite."
  log "         Compare the one wild run: a 145k parent gave back ~13k and rebuilt"
  log "         106k. Same head, bigger loss. The pinger cannot hold a big window."
fi
log ""
log "cost of this probe: $(( ${C1:-0} + ${C2:-0} )) tokens written, $(( ${R1:-0} + ${R2:-0} )) read"

# Ours and worthless now. The ids are remembered so the cycles their Stop hook
# wrote stay out of the medians, the grades and the analytics.
for s in "$S1" "$S2"; do
  [ -n "$s" ] || continue
  printf '%s\n' "${s:0:8}" >> "$FSFORKS"
  rm -f "$CL"/projects/*/"$s".jsonl 2>/dev/null
done
cd "$HOME" || exit 0
rm -rf "$DIR" 2>/dev/null
log ""
log "log written to $OUT"
