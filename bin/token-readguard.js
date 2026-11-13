#!/usr/bin/env node
// PreToolUse hook on Read and Bash: the reading ladder, enforced (2026-09-23, session-hygiene item 3).
//
// A whole-file Read of a text file over MAX lines (no offset/limit) is refused once,
// with the cheaper rungs named. Retrying the SAME full read within RETRY_MIN minutes
// passes: that retry is the "say it out loud, then proceed" skip CLAUDE.md allows,
// and it covers files about to be rewritten. State: token-readguard/<sid>.
// TOKEN_READ_GUARD=0 turns it off; TOKEN_READ_GUARD=<n> sets the line bar.
//
// Bash (2026-11-12): a bare `cat FILE` whose output reaches the model is the same
// whole read by another door - 190 Bash cat/sed/head/tail/awk calls against 303 Reads
// in one week, and only 2 refusals ever. Only `cat` as the last stage of a pipeline
// counts: `cat f | grep`, `sed -n`, `head`, `tail` are already the cheap rungs.
// Wire it with matcher "Read|Bash".
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const MAX = +(process.env.TOKEN_READ_GUARD ?? 500);
const RETRY_MIN = 10;
if (!MAX) process.exit(0);

let p;
try { p = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { process.exit(0); }
const ti = p.tool_input || {};
const SKIP_EXT = /\.(png|jpe?g|gif|webp|bmp|ico|pdf|ipynb)$/i;

// Files this call would read whole into the window.
let targets = [], via = 'Read';
if (p.tool_name === 'Read') {
  if (!ti.file_path || ti.offset != null || ti.limit != null) process.exit(0);
  targets = [ti.file_path];
} else if (p.tool_name === 'Bash' && typeof ti.command === 'string') {
  via = 'cat';
  targets = catTargets(ti.command, p.cwd || process.cwd());
} else process.exit(0);
targets = targets.filter(f => !SKIP_EXT.test(f));
if (!targets.length) process.exit(0);

function catTargets(cmd, cwd) {
  if (/<</.test(cmd)) return [];                        // heredocs: cat writes, not reads
  const out = [];
  let dir = cwd;
  for (const seg of cmd.split(/&&|\|\||;|\n/)) {
    const stages = seg.split('|');
    const words = (stages[0].match(/"[^"]*"|'[^']*'|\S+/g) || []).map(w => w.replace(/^["']|["']$/g, ''));
    if (words[0] === 'cd' && words[1]) { dir = resolve(words[1], dir); continue; }
    if (words[0] !== 'cat' || stages.length > 1) continue;   // piped onward = already filtered
    for (const w of words.slice(1)) {
      if (/^[<>]|^\d?>/.test(w)) break;                  // redirection: rest is not input
      if (w.startsWith('-')) continue;
      out.push(resolve(w, dir));
    }
  }
  return out;
}
function resolve(w, base) {
  w = w.replace(/^~(?=\/|$)/, os.homedir()).replace(/^\$HOME|^\$\{HOME\}/, os.homedir());
  const m = w.match(/^\/([a-zA-Z])\/(.*)$/);           // Git Bash /c/Users -> C:/Users
  if (m && process.platform === 'win32') w = m[1].toUpperCase() + ':/' + m[2];
  return path.resolve(base, w);
}

// Master read-guard (2026-11-11). A master integrates from its lanes' summaries,
// never from their raw output: session 9bde5243 read six lane files of 14-34 KB
// into a 187k window and paid for them on every cycle after. In master mode
// (token-master/<sid>.json exists) a whole Read of anything under _build/ over
// MASTER_KB is refused outright - no retry pass - with the two cheap routes
// named: the lane's `## Summary` table, or a ranged Read of one section.
// TOKEN_MASTER_READ_KB=0 turns it off.
const MASTER_KB = +(process.env.TOKEN_MASTER_READ_KB ?? 8);
const CLDIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const isMaster = MASTER_KB && p.session_id && fs.existsSync(path.join(CLDIR, 'token-master', p.session_id + '.json'));
for (const f of targets) {
  if (!isMaster || !/[\\/]_build[\\/]/.test(f)) continue;
  let kb = 0; try { kb = fs.statSync(f).size / 1024; } catch {}
  if (kb > MASTER_KB) {
    process.stderr.write(
      `[read-guard] master mode: ${path.basename(f)} is ${Math.round(kb)} KB of lane output (bar ${MASTER_KB} KB).\n` +
      `A master integrates from summaries: Grep '^## Summary' -A 45 in that file, or Read one section with offset/limit.\n` +
      `The lane owns the detail; if its Summary is missing, send it back for one (commands/delegate.md).\n`);
    process.exit(2);
  }
}

function lineCount(f) {
  try {
    const st = fs.statSync(f);
    if (!st.isFile() || st.size < MAX * 20) return 0;  // cannot reach MAX lines at any sane width
    const b = fs.readFileSync(f);
    let n = 0; for (let i = 0; i < b.length; i++) if (b[i] === 10) n++;
    return n;
  } catch { return 0; }
}
let f, lines = 0;
for (const t of targets) { const n = lineCount(t); if (n > MAX) { f = t; lines = n; break; } }
if (!f) process.exit(0);

const dir = path.join(CLDIR, 'token-readguard');
const sf = path.join(dir, String(p.session_id || 'nosid'));
const key = path.resolve(f).toLowerCase();
const now = Date.now();
let seen = {};
try { seen = JSON.parse(fs.readFileSync(sf, 'utf8')); } catch {}
if (seen[key] && now - seen[key] < RETRY_MIN * 60000) {
  delete seen[key];
  try { fs.writeFileSync(sf, JSON.stringify(seen)); } catch {}
  process.exit(0);                                      // the announced skip
}
seen[key] = now;
try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(sf, JSON.stringify(seen)); fs.appendFileSync(sf + '.log', `${new Date().toISOString()} ${lines} ${key} ${via}\n`); } catch {}

process.stderr.write(
  `[read-guard] ${path.basename(f)} is ${lines} lines (bar ${MAX}); a whole read${via === 'cat' ? ' (via cat)' : ''} is ~${Math.round(fs.statSync(f).size / 4000)}k tokens of growth at 2x.\n` +
  `Cheaper rungs: Grep (-c, then -n with context), sed -n / Read with offset/limit.\n` +
  `If a full read is really needed (e.g. you are about to rewrite it), say so to the user in one line and repeat the same ${via === 'cat' ? 'command' : 'Read'} within ${RETRY_MIN} min - it will pass.\n`);
process.exit(2);
