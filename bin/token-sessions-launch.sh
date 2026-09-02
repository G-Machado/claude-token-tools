#!/usr/bin/env bash
# Entry point for the "Claude Sessions" desktop shortcut.
#
# The flags live here rather than in the .lnk because shortcut arguments are
# awkward to edit from Explorer. Change the default below and the shortcut
# picks it up next launch - no need to touch the shortcut itself.
#
#   --watch     refresh in place every 60s, keys live   (the default)
#   --browse    same, but opens on the detail panel
#   --analytics same, but opens on the history tab (t toggles it either way)
#   --compact   one line per session, no prompt titles
#   --all       include sessions whose process has exited
#   --ascii     no box-drawing or block glyphs
#   <number>    seconds between refreshes, e.g. 5
#
# Plan percentages on the analytics tab need one calibration, and it lives here
# rather than in the script so it survives an update. Run /usage in Claude Code,
# read what it says you have used this week, then set the ceiling so the two
# agree. Left unset, the tab reports the spend without inventing a limit.
#
#   export TOKEN_PLAN_WEEK_USD=250     # $ of API-equivalent spend per week
#   export TOKEN_PLAN_5H_USD=20        # $ per 5-hour window
#
# Anything passed to this script wins over the default, so the same shortcut
# can be copied and pointed at a different view.

[ $# -gt 0 ] || set -- --watch

exec "$HOME/.claude/token-sessions.sh" "$@"
