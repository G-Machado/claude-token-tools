@echo off
rem token-unpark-launch.cmd - start a widget-resumed session in a clean environment.
rem
rem Why this file exists. A claude.exe spawned from inside another Claude Code
rem session inherits CLAUDE_CODE_CHILD_SESSION and comes up in child-session
rem mode: it looks and answers normally, but transcript saving is off and it
rem never writes ~/.claude/sessions/<pid>.json - so it is invisible to the
rem widget, the poke sweep and every cycle measurement. The failure is silent.
rem
rem The parked widget is exposed to this two ways: its own process may have been
rem started from a session, and the Windows Terminal instance it hands the new
rem tab to may have been. Measured 2026-09-09: the resume of path-preview
rem (winpid 130508) wrote a .key but never a .json, and a probe confirmed the
rem markers survive the wt.exe hand-off intact.
rem
rem So the strip runs here, in the new console, immediately before claude - the
rem last word on the environment whoever the spawner turned out to be.
rem
rem It has to be a .cmd file rather than an inline prefix on the launch command:
rem the identical for /f typed onto the wt.exe command line silently clears
rem nothing (the %i is mangled before cmd sees it), while a script file passes
rem through untouched. Verified both ways before this was written.
rem
rem Wildcard rather than a list of names, because the marker set has grown before
rem and a missed one fails silently. A zero-match loop is harmless: verified that
rem the launch below still runs when the environment is already clean.
for /f "delims==" %%i in ('set CLAUDE 2^>nul') do @set "%%i="
set "AI_AGENT="
claude %*
