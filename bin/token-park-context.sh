#!/usr/bin/env bash
# The context block for /park: what this session has spent, what is already
# parked in this project, and where a new checkpoint would go.
#
# In a file, not inline in the command, because the permission check statically
# analyses that inline string. A command substitution, a variable assignment or
# a conditional in it fails to parse and surfaces as a PERMISSION error rather
# than a syntax one - which sends you to allowed-tools, where the problem is
# not. It cost a fresh session of /unpark to find that out.
#
# It matters more here than anywhere else: /park is the one command with a
# deadline. If it fails at the moment you are stepping away, the fallback is
# paying context x 2 on return.
set -u
CL="$HOME/.claude"

bash "$CL/token-cycles.sh" --status
bash "$CL/token-sessions.sh" --checkpoints --no-color

echo
echo "  this session = ${CLAUDE_CODE_SESSION_ID:-unknown}"
echo "  write to     = $CL/checkpoints/$(basename "$PWD").<topic>.md"

# Branch and HEAD are what /unpark compares the checkpoint against, so they have
# to be recorded accurately here. The dirty COUNT, not the list: a Unity repo
# carries a long tail of modified .meta files as its normal state, and fifteen
# lines of those bury the two that matter.
b=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$b" ]; then
  h=$(git -C "$PWD" log --oneline -1 2>/dev/null)
  d=$(git -C "$PWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "  NOW  branch $b  HEAD $h  ($d files dirty)"
fi
