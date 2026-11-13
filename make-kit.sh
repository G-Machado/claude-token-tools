#!/usr/bin/env bash
# Build a trimmed, shareable copy of the token tools: the workflow kit (levels 0-3)
# without TokenChat, the author's own guard rules, multi-account tooling, research
# probes or the master/delegate lane (level 4 needs TokenChat to route questions).
#
#   ./make-kit.sh [dest]     default dest: ../claude-token-kit (refuses to overwrite)
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$(dirname "$SRC")/claude-token-kit}"
[ -e "$DEST" ] && { echo "refusing: $DEST exists - remove it or pass another path" >&2; exit 1; }

EXCL_BIN="token-cs-gate.js token-guard.js token-window-keeper.sh token-update-retest.sh token-failsafe-probe.sh"
EXCL_WIN="effort-trial-install.ps1 effort-trial.js token-keeper-install.ps1 token-keeper.vbs token-pokedue-install.ps1 token-pokedue.vbs"
CMDS="park unpark handoff arc tokens"
DOCS="WORKFLOW.md COST-MODEL.md INSTALL.md REFERENCE.md TUTORIAL.md failsafe-findings.md pricing-reference.md settings-reference.md"

mkdir -p "$DEST"/bin "$DEST"/windows "$DEST"/commands "$DEST"/share "$DEST"/docs/workflow-kit
for f in "$SRC"/bin/*; do b=$(basename "$f"); case " $EXCL_BIN " in *" $b "*) ;; *) cp -p "$f" "$DEST/bin/";; esac; done
for f in "$SRC"/windows/*; do [ -f "$f" ] || continue; b=$(basename "$f"); case " $EXCL_WIN " in *" $b "*) ;; *) cp -p "$f" "$DEST/windows/";; esac; done
for c in $CMDS; do cp -p "$SRC/commands/$c.md" "$DEST/commands/"; done
cp -p "$SRC"/share/* "$DEST/share/"
for d in $DOCS; do cp -p "$SRC/docs/$d" "$DEST/docs/"; done
for f in "$SRC"/docs/workflow-kit/level-[0-3]*.md "$SRC"/docs/workflow-kit/README.md; do cp -p "$f" "$DEST/docs/workflow-kit/"; done
cp -p "$SRC"/install.sh "$SRC"/uninstall.sh "$SRC"/LICENSE "$SRC"/VERSION "$DEST/"

# Patch text in the copy (node: exact-string, LF-preserving; fails loudly on a miss).
node - "$DEST" <<'NODE'
const fs = require('fs'), path = require('path');
const dest = process.argv[2];
function patch(rel, from, to) {
  const p = path.join(dest, rel), s = fs.readFileSync(p, 'utf8');
  if (!s.includes(from)) { console.error('make-kit: patch target not found in ' + rel + ':\n' + from); process.exit(1); }
  fs.writeFileSync(p, s.replace(from, to), 'utf8');
}
// installer wiring: drop the author's .NET test gate and git/Unity guard
patch('install.sh',
  ' --alert" } ] },\n      { "hooks": [ { "type": "command", "shell": "bash", "timeout": 240,\n          "command": "node \\"$HOME/.claude/token-cs-gate.js\\"" } ] }\n',
  ' --alert" } ] }\n');
patch('install.sh',
  ' "command": "node \\"$HOME/.claude/token-readguard.js\\"" } ] },\n      { "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "shell": "bash", "timeout": 5,\n          "command": "node \\"$HOME/.claude/token-guard.js\\"" } ] }\n',
  ' "command": "node \\"$HOME/.claude/token-readguard.js\\"" } ] }\n');
patch('install.sh', '# files only: windows/token-chat is TokenChat\'s source tree, built and run in place\n', '');
patch('install.sh', '(/park, /unpark, /handoff, ...)', '(/park, /unpark, /handoff, /arc, /tokens)');
// kit index: level 4 is not in this copy
patch('docs/workflow-kit/README.md',
  '| **4 — parallel** | master session + delegate lanes | advanced, opinionated | [level-4-parallel.md](level-4-parallel.md) |',
  '| **4 — parallel** | master session + delegate lanes | not in this copy (needs the author\'s TokenChat app) | — |');
patch('docs/workflow-kit/level-3-guards.md',
  '| `/handoff <topic>` | topic change, or same topic past ~150k: parks, opens a new window on `/unpark`, and makes the old window read-only |',
  '| `/handoff <topic>` | topic change, or same topic past ~150k: parks, opens a new window on `/unpark`, and makes the old window read-only. **Windows only** (opens Windows Terminal); elsewhere run `/park`, `/clear`, `/unpark <topic>` by hand |');
// no network by default: this copy is not a clone of the upstream repo, so its update notice would be wrong
patch('bin/token-sessions.sh',
  'UPDREPO="${TOKEN_UPDATE_REPO:-G-Machado/claude-token-tools}"',
  'UPDREPO="${TOKEN_UPDATE_REPO:-}"');
NODE

# the consent/intent page: what the kit is for, what it changes, what it never does, how to remove it
cp -p "$SRC/docs/workflow-kit/PACKAGE-README.md" "$DEST/README.md"

# double-click launcher: opens Claude Code in the kit folder with the onboarding prompt typed, not sent
L="$SRC/windows/kit-launcher"
if [ ! -f "$L/start-claude.exe" ] || [ "$L/Launcher.cs" -nt "$L/start-claude.exe" ]; then
  cmd //c "$(cygpath -w "$L/build.cmd")" || { echo "make-kit: launcher build failed" >&2; exit 1; }
fi
cp -p "$L/start-claude.exe" "$DEST/"
mkdir -p "$DEST/launcher-source"; cp -p "$L/Launcher.cs" "$L/build.cmd" "$DEST/launcher-source/"
printf '%s\n' "Read README.md and docs/workflow-kit/README.md in this folder, explain in a few lines what this kit would change on my machine, then help me choose and set up a level. Install nothing until I say so." > "$DEST/start-claude.txt"
echo "kit -> $DEST"
