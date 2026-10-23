#!/usr/bin/env bash
# Re-test after `claude update`: the four things the 2.1.288-2.1.309 changelog can break.
#   1. UserPromptSubmit now runs BEFORE slash expansion - what prompt text does a hook see for /park?
#   2. token-block.sh: past 300k, /park /compact /clear /exit pass and a plain prompt is refused.
#   3. widget hook line (token-me.js --line) still prints for a live session.
#   4. token-cycles.sh --status parses the newest transcript (per-request system prompt/tools added).
#   5. stream-json event types: anything TokenChat.Core does not handle (forks default on in -p).
# Checks 1 and 5 spawn `claude -p`; 1 blocks at the hook (no model call), 5 is one tiny turn.
# Synthetic checks run in a temp HOME with a clip.exe shim, so no live state or clipboard is touched.
# Exit = number of failed checks. Raw output stays in $T for inspection.
set -u
C="$HOME/.claude"; T=$(mktemp -d); fail=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
# The live transcript is picked before the probes run: their own headless sessions are newer and print no widget line.
live=$(ls -t "$C"/projects/*/*.jsonl 2>/dev/null | head -1); lsid=$(basename "$live" .jsonl)
echo "claude $(claude --version 2>/dev/null)   scratch: $T"

# 1 -------------------------------------------------------------------------------------------
echo "1. hook prompt text for a slash command"
cat > "$T/dump.sh" <<EOF
cat > "$T/ups.json"; exit 2
EOF
dumpcmd="bash $(cygpath -m "$T/dump.sh" 2>/dev/null || echo "$T/dump.sh")"
node -e 'console.log(JSON.stringify({hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:process.argv[1]}]}]}}))' "$dumpcmd" > "$T/probe-settings.json"
MSYS_NO_PATHCONV=1 claude -p "/park retest-probe" --settings "$(cygpath -m "$T/probe-settings.json" 2>/dev/null || echo "$T/probe-settings.json")" --output-format json > "$T/probe-out.json" 2>&1
if [ -s "$T/ups.json" ]; then
  p=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.prompt).slice(0,80))' "$T/ups.json")
  case "$p" in /park*) ok "hook sees raw '$p' (token-block's /park match works)" ;;
               *) bad "hook sees '$p' - token-block.sh matches /park on the raw text; check it" ;; esac
else bad "UserPromptSubmit hook never fired (see $T/probe-out.json)"; fi

# 2 -------------------------------------------------------------------------------------------
echo "2. token-block.sh past 300k"
H="$T/home"; mkdir -p "$H/.claude" "$T/shim"
printf '#!/bin/sh\ncat >/dev/null\n' > "$T/shim/clip.exe"; chmod +x "$T/shim/clip.exe"
sid=0badc0de-0000-0000-0000-000000000000
printf '%s,%s,0,0,0,310000\n' "$(date +"%Y-%m-%d %H:%M")" "${sid:0:8}" > "$H/.claude/token-history.csv"
blk() { printf '{"session_id":"%s","prompt":"%s"}' "$sid" "$1" |
  HOME="$H" PATH="$T/shim:$PATH" TOKEN_COLD_BLOCK=0 bash "$C/token-block.sh" > /dev/null 2>&1; echo $?; }
for s in "/park x" "/compact" "/clear" "/exit"; do
  r=$(blk "$s"); [ "$r" = 0 ] && ok "'$s' passes" || bad "'$s' refused (exit $r)"; done
r=$(blk "hello"); [ "$r" = 2 ] && ok "plain prompt refused" || bad "plain prompt exit $r, want 2 (synthetic csv row may not match the live format)"

# 3 -------------------------------------------------------------------------------------------
echo "3. widget hook line"
line=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$lsid" "$(cygpath -m "$live" 2>/dev/null || echo "$live")" |
  node "$C/token-me.js" --line 2>"$T/me.err")
[ -n "$line" ] && ok "${line:0:90}" || bad "token-me.js --line printed nothing (stderr: $T/me.err)"

# 4 -------------------------------------------------------------------------------------------
echo "4. token-cycles.sh --status on the newest transcript"
st=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$lsid" "$(cygpath -m "$live" 2>/dev/null || echo "$live")" |
  bash "$C/token-cycles.sh" --status 2>"$T/cyc.err")
case "$st" in *[1-9]*) ok "${st:0:90}" ;; *) bad "--status printed no numbers: '${st:0:90}' (stderr: $T/cyc.err)" ;; esac

# 5 -------------------------------------------------------------------------------------------
echo "5. stream-json event types vs TokenChat.Core"
claude -p "reply with the word ok" --output-format stream-json --verbose --max-turns 1 > "$T/stream.jsonl" 2>"$T/stream.err"
types=$(node -e 'const s=new Set();for(const l of require("fs").readFileSync(process.argv[1],"utf8").split("\n")){try{s.add(JSON.parse(l).type)}catch{}}console.log([...s].join(" "))' "$T/stream.jsonl")
[ -n "$types" ] || bad "no stream-json events (stderr: $T/stream.err)"
known=$(grep -rhoE 'case "[a-z_]+"' "$REPO/windows/token-chat/src/TokenChat.Core" --include=*.cs | sed 's/case "\(.*\)"/\1/' | sort -u)
for t in $types; do
  printf '%s\n' "$known" | grep -qx "$t" && ok "type '$t' handled" || bad "type '$t' not in any TokenChat.Core switch"; done

echo "$fail failed"; exit $fail
