#!/usr/bin/env node
// PostToolUse hook: the in-flight half of the cycle budget (2026-10-23, guardrails B4).
//
// The Stop hook scores a cycle after it ends; by then a bundled prompt has already
// spent its output. This one runs after every tool call, sums this cycle's output
// from the transcript, and the first time it crosses BAR tells me (not the user) to
// stop at a clean point. Once per cycle. Cycles and dedupe follow token-cycles.sh:
// a cycle is a change in promptId on user lines; usage repeats per message id.
// TOKEN_CYCLE_NUDGE=0 turns it off; TOKEN_CYCLE_NUDGE=<n> sets the bar.
// --retune 2026-10-23: 15k output fires on 22% of cycles (top of band).
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const BAR = +(process.env.TOKEN_CYCLE_NUDGE ?? 15000);
if (!BAR) process.exit(0);

let p;
try { p = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { process.exit(0); }
const tp = p.transcript_path;
if (!tp) process.exit(0);

// Tail-read, doubling until the chunk holds the start of the current cycle.
function scan(fd, size, from) {
  const len = size - from;
  const buf = Buffer.alloc(len);
  fs.readSync(fd, buf, 0, len, from);
  let lines = buf.toString('utf8').split('\n');
  if (from > 0) lines = lines.slice(1);                 // first line is partial
  let pid = null, firstPid = null, sawBoundary = false;
  const out = new Map();                                // msg id -> output tokens, current cycle
  for (const l of lines) {
    if (l.includes('"type":"user"')) {
      const m = l.match(/"promptId":"([a-f0-9-]+)"/);
      if (m) {
        if (firstPid === null) firstPid = m[1];
        if (m[1] !== pid) { if (pid !== null) sawBoundary = true; pid = m[1]; out.clear(); }
      }
      continue;
    }
    if (pid === null || !l.includes('"output_tokens"') || l.includes('"isSidechain":true')) continue;
    const o = l.match(/"output_tokens":(\d+)/);
    if (!o) continue;
    const id = (l.match(/msg_[A-Za-z0-9]+/) || [l.length + ':' + out.size])[0];
    out.set(id, Math.max(out.get(id) || 0, +o[1]));
  }
  let total = 0;
  for (const v of out.values()) total += v;
  return { pid, total, complete: from === 0 || sawBoundary };
}

let r;
try {
  const fd = fs.openSync(tp, 'r');
  const size = fs.fstatSync(fd).size;
  for (let chunk = 1 << 20; ; chunk *= 4) {
    const from = Math.max(0, size - chunk);
    r = scan(fd, size, from);
    if (r.complete) break;
  }
  fs.closeSync(fd);
} catch { process.exit(0); }
if (!r.pid || r.total < BAR) process.exit(0);

const dir = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'token-cycle-nudge');
const sf = path.join(dir, String(p.session_id || 'nosid'));
try { if (fs.readFileSync(sf, 'utf8') === r.pid) process.exit(0); } catch {}
try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(sf, r.pid); } catch {}

const k = (r.total / 1000).toFixed(1);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PostToolUse',
    additionalContext: `[token-nudge] This cycle's output is ${k}k (bar ${BAR / 1000}k). ` +
      'Finish the current step to a clean point (code builds/runs, or research has a stated ' +
      'conclusion), then stop and report as a checkpoint: what changed, verified vs assumed, ' +
      'what is next. The user continues next cycle. If what remains is one small step, finish it first.',
  },
}));
