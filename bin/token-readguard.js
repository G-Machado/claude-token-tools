#!/usr/bin/env node
// PreToolUse hook on Read: the reading ladder, enforced (2026-09-23, session-hygiene item 3).
//
// A whole-file Read of a text file over MAX lines (no offset/limit) is refused once,
// with the cheaper rungs named. Retrying the SAME full read within RETRY_MIN minutes
// passes: that retry is the "say it out loud, then proceed" skip CLAUDE.md allows,
// and it covers files about to be rewritten. State: token-readguard/<sid>.
// TOKEN_READ_GUARD=0 turns it off; TOKEN_READ_GUARD=<n> sets the line bar.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const MAX = +(process.env.TOKEN_READ_GUARD ?? 500);
const RETRY_MIN = 10;
if (!MAX) process.exit(0);

let p;
try { p = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { process.exit(0); }
const ti = p.tool_input || {};
const f = ti.file_path;
if (p.tool_name !== 'Read' || !f || ti.offset != null || ti.limit != null) process.exit(0);
if (/\.(png|jpe?g|gif|webp|bmp|ico|pdf|ipynb)$/i.test(f)) process.exit(0);

let lines;
try {
  const st = fs.statSync(f);
  if (!st.isFile()) process.exit(0);
  if (st.size < MAX * 20) process.exit(0);            // cannot reach MAX lines at any sane width
  const b = fs.readFileSync(f);
  lines = 0; for (let i = 0; i < b.length; i++) if (b[i] === 10) lines++;
} catch { process.exit(0); }
if (lines <= MAX) process.exit(0);

const dir = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'token-readguard');
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
try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(sf, JSON.stringify(seen)); fs.appendFileSync(sf + '.log', `${new Date().toISOString()} ${lines} ${key}\n`); } catch {}

process.stderr.write(
  `[read-guard] ${path.basename(f)} is ${lines} lines (bar ${MAX}); a whole read is ~${Math.round(fs.statSync(f).size / 4000)}k tokens of growth at 2x.\n` +
  `Cheaper rungs: Grep (-c, then -n with context), or Read with offset/limit.\n` +
  `If a full read is really needed (e.g. you are about to rewrite it), say so to the user in one line and repeat the same Read within ${RETRY_MIN} min - it will pass.\n`);
process.exit(2);
