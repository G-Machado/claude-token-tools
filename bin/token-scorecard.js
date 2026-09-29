#!/usr/bin/env node
// SessionEnd hook: one scorecard row per session (2026-09-23, session-hygiene item 4).
// Raw quantities only; token-sessions.sh --stats buckets them into the weekly block.
//
//   ts,sid,reason,cycles,peak_ctx,end_ctx,end_heat,usd,pct_read,g_spend,g_churn,g_control,
//   cut_told,cut_taken,read_denied,snap_age_min
//
// cycles/peak_ctx come from token-history.csv (Stop hook); heat, cost and grades from the
// widget snapshot (as fresh as the widget's last collect - snap_age_min says how fresh).
// cut_told = 50k bands token-me.js told this session to cut; cut_taken = told and it ended
// on /clear. read_denied = full reads token-readguard.js refused.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const CL = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const OUT = path.join(CL, 'token-scorecard.csv');
const HEAD = 'ts,sid,reason,cycles,peak_ctx,end_ctx,end_heat,usd,pct_read,g_spend,g_churn,g_control,cut_told,cut_taken,read_denied,snap_age_min';

let p = {};
try { p = JSON.parse(fs.readFileSync(0, 'utf8')); } catch {}
const sid = p.session_id || '';
if (!sid) process.exit(0);
const read = f => { try { return fs.readFileSync(f, 'utf8'); } catch { return ''; } };

let cycles = 0, peak = 0;
for (const l of read(path.join(CL, 'token-history.csv')).split('\n')) {
  const c = l.split(',');
  if (c[1] === sid.slice(0, 8)) { cycles++; peak = Math.max(peak, +c[5] || 0); }
}

let me = null, age = '';
try {
  const s = JSON.parse(read(path.join(CL, 'token-snapshot.json')));
  me = (s.sessions || []).find(r => r.sid === sid);
  age = Math.round((Date.now() / 1000 - s.generated) / 60);
} catch {}

const told = read(path.join(CL, 'token-told', sid)).split('\n').filter(Boolean).length;
const reason = String(p.reason || '');
let denied = 0;
try { denied = read(path.join(CL, 'token-readguard', sid + '.log')).split('\n').filter(Boolean).length; } catch {}

if (!cycles && !me) process.exit(0);                  // nothing ran: not worth a row
const g = (me && me.grades) || {};
const row = [
  new Date().toISOString().slice(0, 16).replace('T', ' '), sid.slice(0, 8), reason, cycles, peak,
  me ? me.context : '', me ? me.hot : '', me ? me.cost.usd.toFixed(3) : '', me ? me.cost.pct_read : '',
  g.spend || '', g.churn || '', g.control || '', told, told && reason === 'clear' ? 1 : 0, denied, age,
].join(',');
try {
  if (!fs.existsSync(OUT)) fs.writeFileSync(OUT, HEAD + '\n');
  fs.appendFileSync(OUT, row + '\n');
} catch {}
