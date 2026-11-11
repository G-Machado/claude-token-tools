#!/usr/bin/env node
// token-sessions.sh --last <sid>: a session's last assistant text and last tool call, three lines.
//
// What it is for (2026-11-11). A master that wants to know what a delegate is doing has two
// options today: read its transcript (tens of KB into the master's window) or read its report
// (which does not exist until it is done). This is the cheap third: the tail of the transcript,
// summarised to what a planner needs - is it working, on what, and what did it last say.
// Nothing here costs model tokens; the output is meant to be small enough to paste into a turn.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const sid = (process.argv[2] || '').trim();
if (!sid) { process.stderr.write('token-last: needs a session id (full or 8-char prefix)\n'); process.exit(2); }
const CL = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');

// The transcript: ~/.claude/projects/<proj-key>/<sid>.jsonl, found by prefix across projects.
let file = null, best = 0;
try {
  for (const d of fs.readdirSync(path.join(CL, 'projects'))) {
    const dir = path.join(CL, 'projects', d);
    let names; try { names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!n.endsWith('.jsonl') || !n.startsWith(sid)) continue;
      const t = fs.statSync(path.join(dir, n)).mtimeMs;
      if (t > best) { best = t; file = path.join(dir, n); }
    }
  }
} catch { }
if (!file) { process.stderr.write(`token-last: no transcript for ${sid}\n`); process.exit(1); }

// Read the tail only: 256 KB is more than one turn of tool output in every measured case.
const size = fs.statSync(file).size, from = Math.max(0, size - 262144);
const fd = fs.openSync(file, 'r'), buf = Buffer.alloc(size - from);
fs.readSync(fd, buf, 0, buf.length, from); fs.closeSync(fd);
const lines = buf.toString('utf8').split('\n');
if (from > 0) lines.shift();                       // a partial first line

let text = null, tool = null, at = null;
for (let i = lines.length - 1; i >= 0 && (!text || !tool); i--) {
  let o; try { o = JSON.parse(lines[i]); } catch { continue; }
  if (o.type !== 'assistant' || !o.message || !Array.isArray(o.message.content)) continue;
  if (!at) at = o.timestamp || null;
  for (const b of o.message.content) {
    if (!tool && b.type === 'tool_use') {
      const inp = b.input || {};
      const arg = inp.command || inp.file_path || inp.pattern || inp.description || inp.prompt || '';
      tool = `${b.name} ${String(arg).replace(/\s+/g, ' ').slice(0, 110)}`.trim();
    }
    if (!text && b.type === 'text' && b.text && b.text.trim()) text = b.text.replace(/\s+/g, ' ').trim().slice(0, 200);
  }
}
const age = at ? Math.round((Date.now() - Date.parse(at)) / 60000) : null;
console.log(`${sid.slice(0, 8)} last turn ${age == null ? '?' : age + 'm ago'}  (${Math.round(size / 1024)} KB transcript)`);
console.log(`text: ${text || '-'}`);
console.log(`tool: ${tool || '-'}`);
