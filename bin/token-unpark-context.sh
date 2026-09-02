#!/usr/bin/env bash
# The context block for /unpark: what is parked in this project, and what the
# working tree looks like right now.
#
# This lives in a file rather than inline in the command because the permission
# check statically analyses that inline string. Anything with a command
# substitution, a variable assignment or a conditional in it fails to parse, and
# the command then reports it as a PERMISSION error rather than a syntax one -
# which sends you looking at allowed-tools, where the problem is not.
#
# So the rule for a command file: one plain invocation, no shell grammar. Put
# the grammar here.
set -u
CL="$HOME/.claude"

bash "$CL/token-sessions.sh" --checkpoints --no-color

# The branch is the field /unpark is told to compare against the checkpoint, and
# it was the one the first version left out. The dirty COUNT rather than the
# list: this repo carries ~95 modified .meta files as its normal state, so the
# list is pure noise and buries the two lines that matter.
b=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$b" ]; then
  h=$(git -C "$PWD" log --oneline -1 2>/dev/null)
  d=$(git -C "$PWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo
  echo "  NOW  branch $b  HEAD $h  ($d files dirty)"
fi
