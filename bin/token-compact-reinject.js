// SessionStart hook: after a /compact (source=compact), re-inject the standing rules of this
// session's checkpoint - Next, Goal, Facts, "Decided - do not reopen", "Verified vs assumed". Compaction is
// known to drop side constraints; the checkpoint file is the invariant store.
// Checkpoint lookup: one stamped with this session id, else the last checkpoint path the
// transcript mentions (an /unpark'd one carries the old session's stamp).
// A master session (token-master/<sid>.json) gets its own plan doc and a one-line master state instead: a delegate's
// brief carries session=<master sid> in its header, so the sid scan would hand the master a delegate's rules.
// Log: token-compact-reinject.log (one row per firing, including misses).
const fs = require('fs'), path = require('path'), os = require('os');
const home = path.join(os.homedir(), '.claude');
const dir = path.join(home, 'checkpoints');
const logf = path.join(home, 'token-compact-reinject.log');
const log = m => { try { fs.appendFileSync(logf, new Date().toISOString() + ' ' + m + '\n'); } catch {} };

let inp = '';
process.stdin.on('data', d => inp += d).on('end', () => {
  let p; try { p = JSON.parse(inp); } catch { return; }
  if (p.source !== 'compact') return;
  const sid = p.session_id || '';
  let file = null, how = '', master = null;
  try { master = JSON.parse(fs.readFileSync(path.join(home, 'token-master', sid + '.json'), 'utf8')); } catch {}
  if (master && !master.master) master = null;
  if (master) {
    const pf = master.plan ? path.join(dir, master.plan) : null;
    if (pf && fs.existsSync(pf)) { file = pf; how = 'master-plan'; }
  } else try {
    for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.md'))) {
      const head = fs.readFileSync(path.join(dir, f), 'utf8').slice(0, 200);
      if (sid && head.includes('session=' + sid)) { file = path.join(dir, f); how = 'sid'; break; }
    }
  } catch {}
  if (!file && !master && p.transcript_path) {
    try {
      const t = fs.readFileSync(p.transcript_path, 'utf8');
      const m = t.match(/checkpoints[\\/]+[A-Za-z0-9._-]+\.md/g);
      if (m) {
        const f = path.join(dir, m[m.length - 1].replace(/^checkpoints[\\/]+/, ''));
        if (fs.existsSync(f)) { file = f; how = 'transcript'; }
      }
    } catch {}
  }
  // token-precompact-park.js supplement: checkpoints/autopark/, stamped autopark=<sid>, appended after the real
  // checkpoint - only when newer than it; an older one describes a state the real checkpoint has replaced.
  let auto = null;
  try {
    const ad = path.join(dir, 'autopark');
    for (const f of fs.readdirSync(ad).filter(f => f.endsWith('.md'))) {
      if (sid && fs.readFileSync(path.join(ad, f), 'utf8').slice(0, 200).includes('autopark=' + sid)) { auto = path.join(ad, f); break; }
    }
    if (auto && file && fs.statSync(auto).mtimeMs <= fs.statSync(file).mtimeMs) { log(`${sid} STALE ${path.basename(auto)} older than ${path.basename(file)}`); auto = null; }
  } catch {}
  if (!file && !auto && !master) { log(`${sid} MISS no checkpoint for this session`); return; }

  const want = /^## (Next|Goal|Facts|Decided|Verified)/;
  const out = [], names = [];
  for (const fp of [file, auto].filter(Boolean)) {
    const got = []; let on = false;
    for (const line of fs.readFileSync(fp, 'utf8').split(/\r?\n/)) {
      if (line.startsWith('## ')) on = want.test(line);
      if (on) got.push(line);
    }
    if (!got.length) { log(`${sid} EMPTY ${path.basename(fp)} has no Next/Goal/Facts/Decided/Verified`); continue; }
    names.push(path.basename(fp));
    if (out.length) out.push('', `(supplement: ${path.basename(fp)} - mechanical, assumed)`, '');
    out.push(...got);
  }
  if (master) {
    out.unshift(`[master] sid=${sid} plan=${master.plan || '-'} delegates=${(master.delegates || []).join(',') || '-'} ` +
      `(check the links: node "$HOME/.claude/token-master.js" status)`, '');
    names.unshift('master state');
  }
  if (!out.length) return;
  log(`${sid} OK ${file ? how : 'autopark'} ${names.join('+')} ${out.length} lines`);
  const ctx = `[post-compact] ${master ? 'Master state and plan' : 'Standing rules from checkpoint'} ${names.join(' + ')} ` +
    `(compaction may have dropped these; treat Decided as settled):\n\n` + out.join('\n');
  process.stdout.write(JSON.stringify({
    systemMessage: `post-compact: re-injected ${names.join(' + ')} (${out.length} lines)`,
    hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: ctx }
  }));
});
