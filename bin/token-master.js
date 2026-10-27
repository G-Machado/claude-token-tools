#!/usr/bin/env node
// token-master.js - state for master plan mode (commands/master.md, commands/answer.md, TokenChat).
//
// One file per master session: ~/.claude/token-master/<full sid>.json
//   { sid, master: true, live, plan, delegates: [slug...], since, liveSince }
// Answers to delegate questions: ~/.claude/token-master/answers/<slug>.json
//   { slug, master, text, at }  - TokenChat watches the folder, answers the delegate's held
//   AskUserQuestion with it and deletes the file. Written whole via a temp file and a rename,
//   so a watcher never reads half of one.
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
//   token-master.js handover <old sid> [--sid NEW]   (handoff: the new window becomes the master)
//   token-master.js status [--sid S] | list
//   token-master.js lease take|release|status [--slug S] [--proj P] [--sid S]
//
// Editor lease (one Unity Editor shared by a master and its --shared delegates):
// ~/.claude/leases/<proj>.json { sid, slug, since }, <proj> = basename of cwd unless --proj.
// take: exit 0 if free, stale (holder sid not a live process) or already ours; exit 1 and the
// holder on stdout if another live session holds it. release: only the holder (exit 1 otherwise).
// Live = some ~/.claude/sessions/<pid>.json names the sid and that pid still runs.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');

const DIR = path.join(os.homedir(), '.claude', 'token-master');
const ANS = path.join(DIR, 'answers');

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
function needSid() { if (!sid) die('no session id: pass --sid or run inside a session'); return sid; }
const now = () => new Date().toISOString();

function show(st) {
  if (!st) { console.log('not a master'); return; }
  console.log(`master ${st.sid.slice(0, 8)}  live=${st.live ? 'on' : 'off'}  plan=${st.plan || '-'}  delegates=${(st.delegates || []).join(',') || '-'}`);
}

const cmd = argv.shift();
switch (cmd) {
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
    const st = load(s);
    if (st && !st.delegates.includes(slug)) process.stderr.write(`token-master: warning: ${slug} is not a listed delegate of this master\n`);
    writeJson(path.join(ANS, slug + '.json'), { slug, master: s, text, at: now() });
    console.log(`answered ${slug}: ${text}`);
    break;
  }
  case 'handover': {
    const s = needSid();
    const old = argv.shift() || die('handover needs the old sid');
    const st = load(old);
    if (!st) die('the old session is not a master', 1);
    st.sid = s;
    st.handedFrom = old;
    if (st.live) st.liveSince = now();
    writeJson(file(s), st);
    try { fs.unlinkSync(file(old)); } catch { }
    show(st);
    break;
  }
  case 'status': show(load(needSid())); break;
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
    const lf = path.join(os.homedir(), '.claude', 'leases', proj + '.json');
    let cur = null;
    try { cur = JSON.parse(fs.readFileSync(lf, 'utf8')); } catch { }
    const desc = l => `${l.sid.slice(0, 8)}${l.slug ? ' (' + l.slug + ')' : ''} since ${l.since}`;
    const live = l => {
      const sd = path.join(os.homedir(), '.claude', 'sessions');
      for (const f of (fs.existsSync(sd) ? fs.readdirSync(sd) : []).filter(f => f.endsWith('.json'))) {
        let r; try { r = JSON.parse(fs.readFileSync(path.join(sd, f), 'utf8')); } catch { continue; }
        if (r.sessionId !== l.sid) continue;
        try { process.kill(r.pid, 0); return true; } catch (e) { if (e.code === 'EPERM') return true; }
      }
      return false;
    };
    if (sub === 'status') {
      if (!cur) console.log(`free ${proj}`);
      else console.log(`held ${proj} by ${desc(cur)}${live(cur) ? '' : ' (stale: holder not live)'}`);
      break;
    }
    const s = needSid();
    if (sub === 'take') {
      if (cur && cur.sid !== s && live(cur)) { console.log(`held ${proj} by ${desc(cur)}`); process.exit(1); }
      const l = { sid: s, slug: slug || (cur && cur.sid === s ? cur.slug : null), since: cur && cur.sid === s ? cur.since : now() };
      writeJson(lf, l);
      console.log(`taken ${proj} by ${desc(l)}${cur && cur.sid !== s ? ' (was stale: ' + desc(cur) + ')' : ''}`);
      break;
    }
    if (sub === 'release') {
      if (!cur) { console.log(`free ${proj}`); break; }
      if (cur.sid !== s) { console.log(`held ${proj} by ${desc(cur)} - not yours`); process.exit(1); }
      fs.unlinkSync(lf);
      console.log(`released ${proj}`);
      break;
    }
    die('lease takes take|release|status');
  }
  default:
    die('usage: on|off|live on|off|add-delegate <slug>|answer <slug> <text>|handover <old sid>|status|list|lease take|release|status');
}
