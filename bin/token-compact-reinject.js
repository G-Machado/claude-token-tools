// SessionStart hook: after a /compact (source=compact), re-inject the standing rules of this
// session's checkpoint - Goal, "Decided - do not reopen", "Verified vs assumed". Compaction is
// known to drop side constraints; the checkpoint file is the invariant store.
// Checkpoint lookup: one stamped with this session id, else the last checkpoint path the
// transcript mentions (an /unpark'd one carries the old session's stamp).
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
  let file = null, how = '';
  try {
    for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.md'))) {
      const head = fs.readFileSync(path.join(dir, f), 'utf8').slice(0, 200);
      if (sid && head.includes('session=' + sid)) { file = path.join(dir, f); how = 'sid'; break; }
    }
  } catch {}
  if (!file && p.transcript_path) {
    try {
      const t = fs.readFileSync(p.transcript_path, 'utf8');
      const m = t.match(/checkpoints[\\/]+[A-Za-z0-9._-]+\.md/g);
      if (m) {
        const f = path.join(dir, m[m.length - 1].replace(/^checkpoints[\\/]+/, ''));
        if (fs.existsSync(f)) { file = f; how = 'transcript'; }
      }
    } catch {}
  }
  if (!file) { log(`${sid} MISS no checkpoint for this session`); return; }

  const txt = fs.readFileSync(file, 'utf8');
  const want = /^## (Goal|Decided|Verified)/;
  const out = []; let on = false;
  for (const line of txt.split(/\r?\n/)) {
    if (line.startsWith('## ')) on = want.test(line);
    if (on) out.push(line);
  }
  if (!out.length) { log(`${sid} EMPTY ${path.basename(file)} has no Goal/Decided/Verified`); return; }
  log(`${sid} OK ${how} ${path.basename(file)} ${out.length} lines`);
  const ctx = `[post-compact] Standing rules from checkpoint ${path.basename(file)} ` +
    `(compaction may have dropped these; treat Decided as settled):\n\n` + out.join('\n');
  process.stdout.write(JSON.stringify({
    systemMessage: `post-compact: re-injected ${path.basename(file)} (${out.length} lines)`,
    hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: ctx }
  }));
});
