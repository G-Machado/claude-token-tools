#!/usr/bin/env node
// token-master.js - state for master plan mode (commands/master.md, commands/answer.md, TokenChat).
//
// One file per master session: ~/.claude/token-master/<full sid>.json
//   { sid, master: true, live, plan, delegates: [slug...], since, liveSince, handedFrom, lineage: [every earlier sid] }
//   handover keeps the whole lineage (A->B->C: C lists A and B), so any sid a delegate was ever briefed with
//   resolves to the master now holding the plan (resolveMaster); files with only handedFrom still load.
// Answers to delegate questions: ~/.claude/token-master/answers/<slug>.json
//   { slug, master, text, at }  - TokenChat watches the folder, answers the delegate's held
//   AskUserQuestion with it and deletes the file. Written whole via a temp file and a rename,
//   so a watcher never reads half of one.
// Answer log: ~/.claude/token-master/log/<master sid>.jsonl, one { at, slug, q, options, a, by } per
//   answered question. TokenChat appends it and answers a repeat of a logged question from it with
//   no master turn; `decided` prints it for delegates. handover moves it to the new sid.
//
// token-sessions.sh reads "live": true straight from these files (no node on that path): a live
// master's extension marks never run out, so it is renewed and never lapse-parked or blocked.
//
// Usage (sid defaults to $CLAUDE_CODE_SESSION_ID):
//   token-master.js on [--plan <proj.topic.md>] [--live] [--sid S]
//   token-master.js off [--sid S]
//   token-master.js live on|off [--sid S]
//   token-master.js add-delegate <slug> [--sid S]
//   token-master.js answer <slug> <text...> [--sid S]
//   token-master.js handover <old sid> [--sid NEW]   (handoff: the new window becomes the master; it also
//                                                    rewrites master=/delegate-of= in this master's delegate briefs)
//   token-master.js resolve <sid>                    (the sid of the master now holding that sid's plan; exit 1 if none)
//   token-master.js status [--sid S] | list          (status also checks each delegate's brief links back: BROKEN if not)
//   token-master.js decided [--master SID]           (the master's Decided + answer log, for a delegate)
//   token-master.js retire <slug> [why...] [--sid S] (its sid from a report/token-delegate.log row of this
//                                                    master's lineage; token-sessions.sh --extend 0 + --block; drops the slug)
//   token-master.js warm <slug> [--sid S]            (alive/running/context_k/cache_left_min + verdict reuse|new;
//                                                    reuse = alive, not running, context < 150k, cache >= 10 min)
//   token-master.js lease take [--wait [--timeout SEC]]|release [--force]|status [--slug S] [--proj P] [--sid S]
//
// Editor lease (one Unity Editor shared by a master and its --shared delegates), a FIFO lock that
// needs no master turn: ~/.claude/leases/<proj>.json { sid, slug, since, queue: [{ sid, slug, at }] },
// <proj> = basename of cwd unless --proj; edited only under leases/<proj>.lock.
// take: exit 0 if free with nobody ahead, stale (holder sid not a live process) or already ours;
// exit 1 and the holder on stdout otherwise. --wait joins the queue and blocks until it is our turn
// (exit 3 at --timeout, default 540s: still queued, run it again). release: the holder, or a waiter
// leaving the queue; --force frees another live holder. Dead holders and waiters are pruned.
// Live = some ~/.claude/sessions/<pid>.json names the sid and that pid still runs.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');

const DIR = path.join(os.homedir(), '.claude', 'token-master');
const ANS = path.join(DIR, 'answers');
const LOG = path.join(DIR, 'log');

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }
function live(s) {
  const sd = path.join(os.homedir(), '.claude', 'sessions');
  for (const f of (fs.existsSync(sd) ? fs.readdirSync(sd) : []).filter(f => f.endsWith('.json'))) {
    let r; try { r = JSON.parse(fs.readFileSync(path.join(sd, f), 'utf8')); } catch { continue; }
    if (r.sessionId !== s) continue;
    try { process.kill(r.pid, 0); return true; } catch (e) { if (e.code === 'EPERM') return true; }
  }
  return false;
}
// An exclusive-create lock file beside p; one older than 10s is a crashed holder's and is broken.
function withLock(p, fn) {
  const lock = p.replace(/\.json$/, '') + '.lock';
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  for (let i = 0; ; i++) {
    try { fs.closeSync(fs.openSync(lock, 'wx')); break; } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 10000) fs.unlinkSync(lock); } catch { }
      if (i > 200) die('lease lock busy: ' + lock);
      sleep(50);
    }
  }
  try { return fn(); } finally { try { fs.unlinkSync(lock); } catch { } }
}

const argv = process.argv.slice(2);
function flag(name) {
  const i = argv.indexOf(name);
  if (i < 0) return null;
  const v = argv[i + 1];
  argv.splice(i, 2);
  return v ?? '';
}
function bool(name) {
  const i = argv.indexOf(name);
  if (i < 0) return false;
  argv.splice(i, 1);
  return true;
}
function die(msg, code = 2) { process.stderr.write('token-master: ' + msg + '\n'); process.exit(code); }

const sidArg = flag('--sid');
const sid = sidArg || process.env.CLAUDE_CODE_SESSION_ID || '';
const file = s => path.join(DIR, s + '.json');

function writeJson(p, o) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = p + '.' + process.pid + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(o, null, 2) + '\n');
  fs.renameSync(tmp, p);
}
function load(s) {
  try { return JSON.parse(fs.readFileSync(file(s), 'utf8')); } catch { return null; }
}
// The master now holding sid's plan: its own file, else the file whose lineage (or legacy handedFrom) names it.
// Reads the folder, so it works with no tab open and after any number of handovers.
function resolveMaster(m) {
  if (!m) return null;
  const own = load(m);
  if (own) return own;
  for (const f of (fs.existsSync(DIR) ? fs.readdirSync(DIR) : []).filter(f => f.endsWith('.json'))) {
    const st = load(f.slice(0, -5));
    if (st && (st.handedFrom === m || (Array.isArray(st.lineage) && st.lineage.includes(m)))) return st;
  }
  return null;
}
const CKPT = path.join(os.homedir(), '.claude', 'checkpoints');
// The park header (line 1) of the newest <proj>.<slug>.md checkpoint, or null.
function briefOf(slug) {
  let best = null;
  try {
    for (const f of fs.readdirSync(CKPT).filter(f => f.endsWith('.' + slug + '.md'))) {
      const fp = path.join(CKPT, f), t = fs.statSync(fp).mtimeMs;
      if (!best || t > best.t) best = { fp, t };
    }
  } catch { }
  if (!best) return null;
  let text; try { text = fs.readFileSync(best.fp, 'utf8'); } catch { return null; }
  const nl = text.indexOf('\n');
  return { fp: best.fp, text, head: nl < 0 ? text : text.slice(0, nl) };
}
const fieldOf = (head, name) => (head.match(new RegExp('(?:^|\\s)' + name + '=([^\\s>-][^\\s>]*)')) || [])[1] || null;
function needSid() { if (!sid) die('no session id: pass --sid or run inside a session'); return sid; }
const now = () => new Date().toISOString();

function show(st, asked) {
  if (!st) { console.log('not a master'); return; }
  console.log(`master ${st.sid.slice(0, 8)}  live=${st.live ? 'on' : 'off'}  plan=${st.plan || '-'}  delegates=${(st.delegates || []).join(',') || '-'}` +
    (asked && asked !== st.sid ? `  (${asked.slice(0, 8)} was handed over)` : ''));
}
// One line per delegate: does its brief's master= still reach this master?
function showLinks(st) {
  for (const slug of st.delegates || []) {
    const b = briefOf(slug);
    const m = b ? fieldOf(b.head, 'master') : null;
    if (!b) { console.log(`  ${slug}  no brief found  (nothing to check)`); continue; }
    if (!m) { console.log(`  ${slug}  no master= in its brief  BROKEN`); continue; }
    const r = resolveMaster(m);
    console.log(`  ${slug}  master=${m.slice(0, 8)}  ` + (r && r.sid === st.sid ? 'ok' : `BROKEN (resolves to ${r ? r.sid.slice(0, 8) : 'nothing'}, not ${st.sid.slice(0, 8)})`));
  }
}

// The sid of a delegate this master opened, from records only this master's lineage writes:
// a checkpoints/reports/*.<slug>.md header with for= in the lineage (sid=), else the newest
// token-delegate.log row (date, event, slug, parent, child sid) with a child sid. Never a guess
// from session titles, so a user's own window cannot be picked up.
function delegateSid(st, slug) {
  const mine = new Set([st.sid, ...(st.lineage || []), ...(st.handedFrom ? [st.handedFrom] : [])]);
  let best = null;
  const rd = path.join(CKPT, 'reports');
  try {
    for (const f of fs.readdirSync(rd).filter(f => f.endsWith('.' + slug + '.md'))) {
      const fp = path.join(rd, f);
      const head = fs.readFileSync(fp, 'utf8').split('\n', 1)[0];
      const s = fieldOf(head, 'sid'), t = fs.statSync(fp).mtimeMs;
      if (s && mine.has(fieldOf(head, 'for')) && (!best || t > best.t)) best = { sid: s, t, from: 'report ' + f };
    }
  } catch { }
  if (best) return best;
  try {
    const rows = fs.readFileSync(path.join(os.homedir(), '.claude', 'token-delegate.log'), 'utf8').split('\n');
    for (let i = rows.length - 1; i >= 0; i--) {
      const c = rows[i].split('\t');
      if (c[2] === slug && mine.has(c[3]) && /^[0-9a-f-]{36}$/.test(c[4] || '')) return { sid: c[4], from: 'token-delegate.log ' + c[1] };
    }
  } catch { }
  return null;
}
const SESSIONS = path.join(os.homedir(), '.claude', 'token-sessions.sh');
function sessions(...args) {
  return require('child_process').spawnSync('bash', [SESSIONS, ...args], { encoding: 'utf8', timeout: 90000, maxBuffer: 64 << 20 });
}

const cmd = argv.shift();
switch (cmd) {
  case 'retire': {
    const s = needSid();
    const slug = argv.shift() || die('retire needs a slug');
    const why = argv.join(' ').trim() || `retired by master ${s.slice(0, 8)}: ${slug} done`;
    const st = resolveMaster(s);
    if (!st) die('not a master');
    const d = delegateSid(st, slug);
    if (!d) die(`no sid for ${slug} in this master's reports or token-delegate.log; nothing retired`, 1);
    if (d.sid === s) die('that is this session');
    for (const a of [['--extend', d.sid, '0'], ['--block', d.sid, why]]) {
      const r = sessions(...a);
      if (r.status !== 0) die(`token-sessions.sh ${a[0]} failed (${r.status}): ${(r.stderr || r.error || '').toString().trim()}`, 1);
    }
    st.delegates = (st.delegates || []).filter(x => x !== slug);
    writeJson(file(st.sid), st);
    console.log(`retired ${slug} ${d.sid.slice(0, 8)} (from ${d.from}): extend 0, blocked "${why}". Tell the user to close its tab.`);
    show(st);
    break;
  }
  case 'warm': {
    const s = needSid();
    const slug = argv.shift() || die('warm needs a slug');
    const st = resolveMaster(s);
    if (!st) die('not a master');
    const d = delegateSid(st, slug);
    if (!d) { console.log(`${slug}  no sid recorded  verdict=new`); break; }
    const r = sessions('--json');
    let rows; try { rows = JSON.parse(r.stdout); } catch { die('token-sessions.sh --json gave no JSON: ' + (r.stderr || r.error || '').toString().trim(), 1); }
    rows = Array.isArray(rows) ? rows : rows.sessions || [];
    const x = rows.find(o => o.sid === d.sid);
    if (!x) { console.log(`${slug}  ${d.sid.slice(0, 8)}  not listed (closed)  verdict=new`); break; }
    const num = v => (v === '' || v == null ? NaN : Number(v));
    const alive = num(x.alive) === 1, running = num(x.running) === 1, ctx = num(x.context_k), cache = num(x.cache_left_min);
    const why = [!alive && 'not alive', running && 'running', !(ctx < 150) && 'context >= 150k', !(cache >= 10) && 'cache < 10 min'].filter(Boolean);
    console.log(`${slug}  ${d.sid.slice(0, 8)}  name=${x.name || '-'}  alive=${x.alive} running=${x.running} context_k=${x.context_k} cache_left_min=${x.cache_left_min}  ` +
      `verdict=${why.length ? 'new (' + why.join(', ') + ')' : 'reuse'}`);
    break;
  }
  case 'on': {
    const s = needSid();
    const plan = flag('--plan');
    const live = bool('--live');
    const st = load(s) || { sid: s, master: true, live: false, plan: null, delegates: [], since: now() };
    st.master = true;
    if (plan) st.plan = plan;
    if (live && !st.live) { st.live = true; st.liveSince = now(); }
    writeJson(file(s), st);
    show(st);
    break;
  }
  case 'off': {
    const s = needSid();
    try { fs.unlinkSync(file(s)); } catch { }
    console.log('master off ' + s.slice(0, 8));
    break;
  }
  case 'live': {
    const s = needSid();
    const want = argv.shift();
    if (want !== 'on' && want !== 'off') die('live takes on or off');
    const st = load(s);
    if (!st) die('not a master: run on first');
    st.live = want === 'on';
    st.liveSince = st.live ? now() : null;
    writeJson(file(s), st);
    show(st);
    break;
  }
  case 'add-delegate': {
    const s = needSid();
    const slug = argv.shift() || die('add-delegate needs a slug');
    const st = load(s);
    if (!st) die('not a master');
    // Admission control (2026-11-11). Six delegates at once on 2026-11-10 put four of them into the
    // 5-hour limit at 22:32, each then needing a cswap and a "write partial output first" nudge. A new
    // delegate is admitted only while (a) fewer than TOKEN_DELEGATE_MAX_LIVE (3) of this master's
    // delegates are alive and (b) the active account's 5-hour headroom covers them all: each live
    // delegate plus this one is booked at TOKEN_DELEGATE_PCT_EACH (15%) of the window - the measured
    // 54-72k cold floor plus a round of work. --force admits anyway; the refusal names the spare
    // account when one has room, so `cswap switch <n>` first is the usual answer.
    if (!bool('--force') && !st.delegates.includes(slug)) {
      const maxLive = +(process.env.TOKEN_DELEGATE_MAX_LIVE ?? 3), each = +(process.env.TOKEN_DELEGATE_PCT_EACH ?? 15);
      const alive = st.delegates.filter(d => { const ds = delegateSid(st, d); return ds && live(ds); });
      if (alive.length >= maxLive)
        die(`admission refused: ${alive.length} delegates live (${alive.join(', ')}); the bar is ${maxLive}. Retire one first, or --force.`, 3);
      let acc = null;
      try { acc = JSON.parse(sessions('--json', '--no-update-check').stdout || '{}').limits; } catch { }
      const act = acc && Array.isArray(acc.accounts) ? acc.accounts.find(a => a.active == 1) : null;
      if (act && typeof act.five_hour_pct === 'number') {
        const need = (alive.length + 1) * each, room = 100 - act.five_hour_pct;
        if (room < need) {
          const spare = acc.accounts.filter(a => a.active != 1 && a.status === 'ok').sort((a, b) => a.five_hour_pct - b.five_hour_pct)[0];
          die(`admission refused: account ${act.n} has ${room}% of its 5-hour window left; ${alive.length} live + 1 need ~${need}% (${each}% each). `
            + (spare ? `cswap switch ${spare.n} (${spare.five_hour_pct}% used) first, or ` : 'Wait for the reset (' + act.five_hour_in + '), or ') + '--force.', 3);
        }
      }
    }
    if (!st.delegates.includes(slug)) st.delegates.push(slug);
    writeJson(file(s), st);
    show(st);
    break;
  }
  case 'answer': {
    const s = needSid();
    const slug = argv.shift() || die('answer needs a slug');
    const text = argv.join(' ').trim();
    if (!text) die('answer needs text');
    const st = resolveMaster(s);
    if (st && !st.delegates.includes(slug)) process.stderr.write(`token-master: warning: ${slug} is not a listed delegate of this master\n`);
    writeJson(path.join(ANS, slug + '.json'), { slug, master: st ? st.sid : s, text, at: now() });
    console.log(`answered ${slug}: ${text}`);
    break;
  }
  case 'handover': {
    const s = needSid();
    const old = argv.shift() || die('handover needs the old sid');
    const st = resolveMaster(old);
    if (!st) die('the old session is not a master', 1);
    const was = st.sid;
    st.lineage = [...new Set([...(st.lineage || []), ...(st.handedFrom ? [st.handedFrom] : []), was, old])].filter(x => x !== s);
    st.sid = s;
    st.handedFrom = was;
    if (st.live) st.liveSince = now();
    writeJson(file(s), st);
    if (was !== s) try { fs.unlinkSync(file(was)); } catch { }
    for (const prev of st.lineage) {
      const oldLog = path.join(LOG, prev + '.jsonl');
      try { fs.appendFileSync(path.join(LOG, s + '.jsonl'), fs.readFileSync(oldLog)); fs.unlinkSync(oldLog); } catch { }
    }
    // Briefs already written keep resolving through the lineage; rewriting them makes the link direct again.
    let fixed = 0;
    for (const slug of st.delegates || []) {
      const b = briefOf(slug);
      if (!b) continue;
      const head = b.head.replace(/((?:^|\s)(?:master|delegate-of)=)(\S+?)(?=\s|-->|$)/g, (m, k, v) => st.lineage.includes(v) ? k + s : m);
      if (head !== b.head) { fs.writeFileSync(b.fp, head + b.text.slice(b.head.length)); fixed++; }
    }
    show(st);
    if (fixed) console.log(`rewrote master=/delegate-of= in ${fixed} delegate brief(s)`);
    break;
  }
  case 'resolve': {
    const st = resolveMaster(argv.shift() || sid);
    if (!st) die('not a master, and no master lists it in its lineage', 1);
    console.log(st.sid);
    break;
  }
  case 'status': {
    const asked = needSid();
    const st = resolveMaster(asked);
    show(st, asked);
    if (st) showLinks(st);
    break;
  }
  case 'list': {
    let n = 0;
    for (const f of (fs.existsSync(DIR) ? fs.readdirSync(DIR) : []).filter(f => f.endsWith('.json'))) {
      const st = load(f.slice(0, -5));
      if (st) { show(st); n++; }
    }
    if (!n) console.log('no masters');
    break;
  }
  case 'lease': {
    const sub = argv.shift();
    const slug = flag('--slug');
    const proj = flag('--proj') || path.basename(process.cwd());
    const wait = bool('--wait');
    const force = bool('--force');
    const timeout = Number(flag('--timeout') || 540);
    const lf = path.join(os.homedir(), '.claude', 'leases', proj + '.json');
    const desc = l => `${l.sid.slice(0, 8)}${l.slug ? ' (' + l.slug + ')' : ''} since ${l.since}`;
    const read = () => { let c = null; try { c = JSON.parse(fs.readFileSync(lf, 'utf8')); } catch { } return c || {}; };
    // Under the lock: a dead holder or a dead waiter drops out, so the queue never stalls on a closed tab.
    const prune = c => {
      if (c.sid && !live(c.sid)) { c.stale = desc(c); c.sid = null; }
      c.queue = (c.queue || []).filter(q => live(q.sid));
      return c;
    };
    const save = c => {
      if (!c.sid && !c.queue.length) { try { fs.unlinkSync(lf); } catch { } return; }
      const o = { ...c }; delete o.stale;
      writeJson(lf, o);
    };
    const queueText = c => c.queue.length ? '  queue: ' + c.queue.map(q => q.sid.slice(0, 8) + (q.slug ? ' (' + q.slug + ')' : '')).join(', ') : '';
    if (sub === 'status') {
      const c = withLock(lf, () => prune(read()));
      console.log((c.sid ? `held ${proj} by ${desc(c)}` : `free ${proj}`) + queueText(c));
      break;
    }
    const s = needSid();
    if (sub === 'take') {
      // FIFO: the lease goes to the head of the queue once it is free. --wait joins the queue and blocks until then
      // (at most --timeout seconds, under the Bash tool's 600s); exit 3 = still queued, run the same command again.
      const deadline = Date.now() + timeout * 1000;
      for (;;) {
        const r = withLock(lf, () => {
          const c = prune(read());
          if (c.sid === s) return { ok: true, c };
          const pos = c.queue.findIndex(q => q.sid === s);
          if (!c.sid && (pos === 0 || (pos < 0 && !c.queue.length))) {
            c.queue = c.queue.filter(q => q.sid !== s);
            c.sid = s; c.slug = slug || null; c.since = now();
            save(c);
            return { ok: true, c, was: c.stale };
          }
          if (wait && pos < 0) { c.queue.push({ sid: s, slug: slug || null, at: now() }); save(c); }
          return { ok: false, c };
        });
        if (r.ok) { console.log(`taken ${proj} by ${desc(r.c)}${r.was ? ' (was stale: ' + r.was + ')' : ''}`); break; }
        const pos = r.c.queue.findIndex(q => q.sid === s);
        const held = (r.c.sid ? `held ${proj} by ${desc(r.c)}` : `free ${proj}`) + queueText(r.c);
        if (!wait) { console.log(held); process.exit(1); }
        if (Date.now() >= deadline) { console.log(`${held}\nstill queued at ${pos + 1} - run the same command again`); process.exit(3); }
        sleep(2000);
      }
      break;
    }
    if (sub === 'release') {
      // The holder releases; a waiter that gives up leaves the queue the same way. --force: the master or the user
      // frees a lease a live session forgot.
      const msg = withLock(lf, () => {
        const c = prune(read());
        const inQ = c.queue.some(q => q.sid === s);
        c.queue = c.queue.filter(q => q.sid !== s);
        if (c.sid && (c.sid === s || force)) {
          const was = c.sid === s ? '' : ' (forced from ' + desc(c) + ')';
          c.sid = null; c.slug = null; c.since = null;
          save(c);
          return { text: `released ${proj}${was}` + (c.queue.length ? `, next ${c.queue[0].sid.slice(0, 8)}` : '') };
        }
        save(c);
        if (inQ) return { text: `left the queue for ${proj}` };
        if (!c.sid) return { text: `free ${proj}` };
        return { text: `held ${proj} by ${desc(c)} - not yours`, code: 1 };
      });
      console.log(msg.text);
      if (msg.code) process.exit(msg.code);
      break;
    }
    die('lease takes take|release|status');
  }
  case 'decided': {
    // What a delegate checks before asking its master: the plan doc's Decided section and the answer log TokenChat
    // keeps (token-master/log/<master sid>.jsonl). --master follows handovers to the master now holding the plan.
    let m = flag('--master') || sid;
    if (!m) die('decided needs --master <sid>');
    const st0 = resolveMaster(m);
    if (st0) m = st0.sid;
    const st = load(m);
    if (!st) die(`${m.slice(0, 8)} is not a master`, 1);
    const plan = st.plan ? path.join(os.homedir(), '.claude', 'checkpoints', st.plan) : null;
    let text = '';
    try { text = fs.readFileSync(plan, 'utf8'); } catch { }
    const lines = text.replace(/\r/g, '').split('\n');
    const at = lines.findIndex(l => /^#+\s*Decided/i.test(l));
    console.log(`# Decided - ${st.plan || 'no plan doc'}`);
    if (at >= 0) {
      for (const l of lines.slice(at + 1)) { if (/^#+\s/.test(l)) break; if (l.trim()) console.log(l); }
    } else console.log('(no Decided section)');
    const rows = [];
    try {
      for (const l of fs.readFileSync(path.join(LOG, m + '.jsonl'), 'utf8').split('\n'))
        if (l.trim()) try { rows.push(JSON.parse(l)); } catch { }
    } catch { }
    console.log(`# Answered (${rows.length})`);
    for (const r of rows.slice(-40)) console.log(`- [${r.slug}] ${r.q} -> ${r.a}`);
    break;
  }
  default:
    die('usage: on|off|live on|off|add-delegate <slug>|answer <slug> <text>|handover <old sid>|status|list|decided [--master S]|lease take [--wait]|release [--force]|status');
}
