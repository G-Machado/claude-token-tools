// Stop hook: if the turn left TokenChat's C# different from the last state that passed, build to bin/Fresh (the running
// app locks bin/Debug) and run tests/TokenChat.Core.Tests. Blocks the stop only on failure, with the error lines, so the
// failure is fixed in the same cycle. Silent when nothing changed or outside the TokenChat tree.
// Fingerprint: git diff HEAD + untracked *.cs/*.xaml/*.csproj under src/ and tests/ - per repo, not per session, and
// saved on pass AND fail: each tree state is built once, so a failure blocks once (reported, not blocked, under
// stop_hook_active) and other strands' dirty files cost one build, then nothing. A lock keeps two sessions from building
// to bin/Fresh at once. The tree is found from cwd upward, also as <ancestor>/windows/token-chat (sessions at the repo
// root). Log: token-cs-gate.log, ts sid verdict seconds.
const fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process'), crypto = require('crypto');
const home = path.join(os.homedir(), '.claude');
const logf = path.join(home, 'token-cs-gate.log'), statef = path.join(home, 'token-cs-gate.state');
const lockf = path.join(home, 'token-cs-gate.lock');
const log = m => { try { fs.appendFileSync(logf, new Date().toISOString() + ' ' + m + '\n'); } catch {} };

const isTree = d => fs.existsSync(path.join(d, 'src', 'TokenChat.App')) && fs.existsSync(path.join(d, 'tests', 'TokenChat.Core.Tests'));
function root(dir) {
  for (let d = dir, i = 0; d && i < 10; d = path.dirname(d), i++) {
    for (const c of [d, path.join(d, 'windows', 'token-chat')]) if (isTree(c)) return c;
    if (path.dirname(d) === d) break;
  }
  return null;
}

// Exclusive create; a lock older than the hook's 240s timeout is a crashed run's and is taken over.
function lock() {
  try { fs.writeFileSync(lockf, String(process.pid), { flag: 'wx' }); return true; }
  catch {
    try { if (Date.now() - fs.statSync(lockf).mtimeMs > 300e3) { fs.writeFileSync(lockf, String(process.pid)); return true; } } catch {}
    return false;
  }
}
const run = (cmd, args, cwd) => cp.spawnSync(cmd, args, { cwd, encoding: 'utf8', maxBuffer: 64 << 20, shell: false });

let inp = '';
process.stdin.on('data', d => inp += d).on('end', () => {
  let p; try { p = JSON.parse(inp); } catch { return; }
  const r = root(p.cwd || process.cwd()); if (!r) return;
  // Pathspecs are a union, so each entry carries both the folder and the extension.
  const spec = ['--', ...['src', 'tests'].flatMap(d => ['cs', 'xaml', 'csproj'].map(x => `:(glob)${d}/**/*.${x}`))];
  const diff = run('git', ['diff', 'HEAD', ...spec], r).stdout || '';
  const untracked = (run('git', ['ls-files', '--others', '--exclude-standard', ...spec], r).stdout || '').split('\n').filter(Boolean);
  const h = crypto.createHash('sha1').update(diff);
  for (const f of untracked) { try { h.update(f + '\0' + fs.readFileSync(path.join(r, f))); } catch {} }
  const fp = r + ' ' + h.digest('hex');
  let last = ''; try { last = fs.readFileSync(statef, 'utf8'); } catch {}
  if (last === fp) return;

  const t0 = Date.now(), sid = p.session_id || '-';
  if (!lock()) { log(`${sid} BUSY another session is building`); return; }
  let b, t;
  try {
    b = run('dotnet', ['build', 'src/TokenChat.App', '-o', 'bin/Fresh', '-v', 'q', '-nologo'], r);
    t = b.status === 0 ? run('dotnet', ['test', 'tests/TokenChat.Core.Tests', '-v', 'q', '-nologo'], r) : null;
  } finally { try { fs.unlinkSync(lockf); } catch {} }
  const secs = ((Date.now() - t0) / 1000).toFixed(0);
  try { fs.writeFileSync(statef, fp); } catch {}
  if (b.status === 0 && t.status === 0) {
    log(`${sid} PASS ${secs}s`);
    process.stdout.write(JSON.stringify({ systemMessage: `cs-gate: build + tests pass (${secs}s)` }));
    return;
  }
  const what = b.status !== 0 ? 'build' : 'tests';
  const out = ((b.status !== 0 ? b : t).stdout || '') + ((b.status !== 0 ? b : t).stderr || '');
  const lines = [...new Set(out.split(/\r?\n/).filter(l => /error|falha|failed|\bFAIL\b|Assert/i.test(l)).map(l => l.trim()))].slice(0, 15);
  log(`${sid} FAIL ${what} ${secs}s ${lines.length} lines${p.stop_hook_active ? ' (reported, not blocked)' : ''}`);
  const reason = `[cs-gate] TokenChat ${what} failed (dotnet ${what === 'build' ? 'build -o bin/Fresh' : 'test tests/TokenChat.Core.Tests'}):\n` + lines.join('\n');
  if (p.stop_hook_active) process.stdout.write(JSON.stringify({ systemMessage: reason }));
  else process.stdout.write(JSON.stringify({ decision: 'block', reason }));
});
