#!/usr/bin/env node
// What the token widget shows, readable by the session it describes (2026-09-23).
//
// Reads ~/.claude/token-snapshot.json, which token-sessions.sh --json leaves on
// disk every time the widget collects. No model tokens, no 6s collect on the
// fast path.
//
//   node token-me.js              full readout for this session (+ others at risk)
//   node token-me.js --line       one line, for the UserPromptSubmit feed
//   node token-me.js --json       this session's raw widget row
//   node token-me.js --refresh    re-collect first (~6s) instead of trusting the file
//   node token-me.js --sid <id>   another session (default: CLAUDE_CODE_SESSION_ID,
//                                 or session_id from a hook payload on stdin)
'use strict';
const fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process');
const CL = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const SNAP = path.join(CL, 'token-snapshot.json');
const args = process.argv.slice(2);
const has = f => args.includes(f);
const argv = f => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };

// Hook payload first: it names the session being prompted, which is the one to describe.
let sid = argv('--sid') || '';
if (!sid && has('--line') && !process.stdin.isTTY) {
  try { const m = fs.readFileSync(0, 'utf8').match(/"session_id"\s*:\s*"([^"]+)"/); if (m) sid = m[1]; } catch {}
}
if (!sid) sid = process.env.CLAUDE_CODE_SESSION_ID || '';

if (has('--refresh') || !fs.existsSync(SNAP)) {
  try { cp.execFileSync('bash', [path.join(CL, 'token-sessions.sh'), '--json'], { stdio: 'ignore', timeout: 30000 }); } catch {}
}
let snap;
try { snap = JSON.parse(fs.readFileSync(SNAP, 'utf8')); }
catch (e) { if (!has('--line')) console.error('token-me: no readable snapshot at ' + SNAP); process.exit(has('--line') ? 0 : 1); }

const C = snap.constants || {}, age = Math.round((Date.now() / 1000 - snap.generated) / 60);
const k = v => (v / 1000).toFixed(0) + 'k';
const me = (snap.sessions || []).find(s => sid && (s.sid === sid || s.sid.startsWith(sid)));
const others = (snap.sessions || []).filter(s => s !== me && s.alive && s.context >= 60000 && s.cache_left_min >= 0 && s.cache_left_min <= 15);
const stale = age > 10 ? ` (snapshot ${age}m old - widget not collecting?)` : '';

if (has('--json')) { console.log(JSON.stringify(me || null, null, 1)); process.exit(0); }

if (!me) {
  if (!has('--line')) console.log(`token-me: session ${sid || '(unknown)'} not in snapshot${stale}; try --refresh`);
  process.exit(0);
}

const cache = me.cache_left_min > 0 ? `${me.cache_left_min}m` : 'COLD';
const marks = `${me.ext_left}/${me.ext_allowed}`;
// Claude Code's own cache verdict (2026-09-29). A non-1h lifetime breaks every timing rule, so it shouts.
const hit = me.hit_pct != null ? ` hit ${me.hit_pct}%` : '';
const ttlw = me.cache_ttl && me.cache_ttl !== '1h' ? ` TTL ${me.cache_ttl}!` : '';
const oth = others.map(s => `${s.short} ${k(s.context)} ${s.cache_left_min}m`).join(', ');

if (has('--line')) {
  // One line into the model's context per prompt, so keep it to what changes a decision.
  console.log(`[widget${stale}] ctx ${k(me.context)} (cut ${C.cut_no}k) heat ${me.hot}x verdict ${me.verdict}` +
    ` | cache ${cache}${ttlw}${hit} marks ${marks}${me.parked ? ' parked' : ''}${me.blocked ? ' BLOCKED' : ''}` +
    ` | spent $${me.cost.usd.toFixed(2)} (read ${me.cost.pct_read}%)` +
    (oth ? ` | lapsing soon: ${oth}` : ''));
  // Say-it-once cut instruction (hygiene rule 1, made mechanical): the first prompt that
  // lands in a new 50k band while the window is past the cut gets an ACTION line;
  // token-told/<sid> remembers the bands already told. Heat no longer fires it
  // (2026-09-23): it divides by output, so short efficient answers read as hot.
  if (me.verdict === 'cut') {
    const band = Math.floor(me.context / 50000) * 50;
    const dir = path.join(CL, 'token-told'), f = path.join(dir, me.sid);
    let told = '';
    try { told = fs.readFileSync(f, 'utf8'); } catch {}
    if (!told.split('\n').includes(String(band))) {
      console.log(`ACTION: window ${k(me.context)}, verdict ${me.verdict}, heat ${me.hot}x` +
        ` - tell the user once: finish the current task, then /park + /clear at the next stopping point (told once for the ${band}k band)`);
      try { fs.mkdirSync(dir, { recursive: true }); fs.appendFileSync(f, band + '\n'); } catch {}
    }
  }
  process.exit(0);
}

console.log(`widget view of ${me.short} "${me.nick}"  (snapshot ${age}m old)`);
console.log(`  context   ${k(me.context)}   cut bar ${C.cut_no}k   overheat ${C.overheat}k   park-at ${C.park_at}k`);
console.log(`  heat      ${me.hot}x  (rent vs work; >=1 costs more to hold than it produces)   verdict: ${me.verdict}`);
console.log(`  cache     ${cache}   extension marks ${marks}   parked ${me.parked ? 'yes (' + me.ck_topic + ')' : 'no'}   blocked ${me.blocked ? 'yes' : 'no'}`);
console.log(`  cycles    ${me.cycles}   output last ${k(me.output_last)}   growth total ${k(me.growth_total)}   breaches ${me.breaches}`);
console.log(`  spent     $${me.cost.usd.toFixed(2)}   output ${me.cost.pct_output}% / write ${me.cost.pct_write}% / read ${me.cost.pct_read}%   grades ${me.grades.spend}/${me.grades.churn}/${me.grades.control}`);
console.log(`  if it lapses: ~${k(me.lapse_cost)} weighted rewrite`);
if (oth) console.log(`  other windows lapsing within 15m: ${oth}`);
const a = snap.alert || {};
if (a.level) console.log(`  plan: ${a.level}, ${a.left_pct}% left`);
