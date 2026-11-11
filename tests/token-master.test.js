// node tests/token-master.test.js - handover lineage, brief rewriting, status link check and the post-compact reinject,
// all in a temp HOME (never the real ~/.claude); exit = failures.
const { spawnSync } = require('child_process'), path = require('path'), os = require('os'), fs = require('fs');
const bin = n => path.join(__dirname, '..', 'bin', n);
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'master-test-'));
const claude = path.join(home, '.claude'), md = path.join(claude, 'token-master'), ck = path.join(claude, 'checkpoints');
fs.mkdirSync(md, { recursive: true }); fs.mkdirSync(ck, { recursive: true });
const env = { ...process.env, HOME: home, USERPROFILE: home, CLAUDE_CODE_SESSION_ID: '' };
const run = (args, input) => { const r = spawnSync('node', args, { env, input, encoding: 'utf8' }); return { code: r.status, out: (r.stdout || '') + (r.stderr || '') }; };
const tm = (...a) => run([bin('token-master.js'), ...a]);
let fails = 0;
const ok = (name, cond, extra = '') => { if (!cond) { fails++; console.log('FAIL ' + name + (extra ? '\n' + extra : '')); } else console.log('ok   ' + name); };
const A = 'aaaaaaaa-0000-0000-0000-000000000001', B = 'bbbbbbbb-0000-0000-0000-000000000002', C = 'cccccccc-0000-0000-0000-000000000003';
const brief = (slug, master, extra = '') => fs.writeFileSync(path.join(ck, `proj.${slug}.md`),
  `<!-- park: session=${master} topic=${slug} cwd=/x delegate-of=${master} master=${master}${extra} -->\n# body ${slug}\n\n## Decided - do not reopen\n- keep\n`);

// A is a master with a plan, a Decided section and an answer log; two delegates are briefed against A.
fs.writeFileSync(path.join(ck, 'proj.plan.md'), '<!-- park: session=' + A + ' topic=plan -->\n# plan\n\n## Next\n1. master step\n\n## Decided - do not reopen\n- master rule one\n\n## Notes\nskipped\n');
tm('on', '--sid', A, '--plan', 'proj.plan.md');
tm('add-delegate', 'alpha', '--sid', A); tm('add-delegate', 'beta', '--sid', A);
brief('alpha', A); brief('beta', A);
fs.mkdirSync(path.join(md, 'log'), { recursive: true });
fs.writeFileSync(path.join(md, 'log', A + '.jsonl'), JSON.stringify({ slug: 'alpha', q: 'Q one?', a: 'yes' }) + '\n');

ok('status of a fresh master: both links ok', /alpha {2}master=aaaaaaaa {2}ok/.test(tm('status', '--sid', A).out) && !/BROKEN/.test(tm('status', '--sid', A).out), tm('status', '--sid', A).out);

// A -> B, then B -> C: the second hop is the one that used to break everything briefed before it.
let h = tm('handover', A, '--sid', B); ok('handover A->B', h.code === 0 && /rewrote .* 2 delegate brief/.test(h.out), h.out);
fs.writeFileSync(path.join(ck, 'proj.gamma.md'), fs.readFileSync(path.join(ck, 'proj.alpha.md'), 'utf8').split(B).join(A)); // a brief still naming A
h = tm('handover', B, '--sid', C); ok('handover B->C', h.code === 0, h.out);
const st = JSON.parse(fs.readFileSync(path.join(md, C + '.json'), 'utf8'));
ok('lineage lists A and B', Array.isArray(st.lineage) && st.lineage.includes(A) && st.lineage.includes(B) && !st.lineage.includes(C), JSON.stringify(st.lineage));
ok('old master files are gone', !fs.existsSync(path.join(md, A + '.json')) && !fs.existsSync(path.join(md, B + '.json')));
for (const old of [A, B]) {
  const d = tm('decided', '--master', old);
  ok(`decided from ${old.slice(0, 1)} reaches C`, d.code === 0 && /master rule one/.test(d.out) && /Q one\? -> yes/.test(d.out), d.out);
  const r = tm('resolve', old); ok(`resolve ${old.slice(0, 1)} = C`, r.out.trim() === C, r.out);
  const s = tm('status', '--sid', old); ok(`status from ${old.slice(0, 1)} shows C`, /^master cccccccc/.test(s.out) && /was handed over/.test(s.out), s.out);
  tm('answer', 'alpha', 'go', 'ahead', '--sid', old);
  const a = JSON.parse(fs.readFileSync(path.join(md, 'answers', 'alpha.json'), 'utf8'));
  ok(`answer via ${old.slice(0, 1)} is written for C`, a.master === C && a.text === 'go ahead', JSON.stringify(a));
}
ok('answer log moved to C', fs.existsSync(path.join(md, 'log', C + '.jsonl')) && !fs.existsSync(path.join(md, 'log', A + '.jsonl')));
ok('alpha brief rewritten to C', /master=cccccccc/.test(fs.readFileSync(path.join(ck, 'proj.alpha.md'), 'utf8').split('\n')[0]) && /delegate-of=cccccccc/.test(fs.readFileSync(path.join(ck, 'proj.alpha.md'), 'utf8').split('\n')[0]));
ok('brief body untouched', /# body alpha/.test(fs.readFileSync(path.join(ck, 'proj.alpha.md'), 'utf8')));
const s0 = tm('status', '--sid', C); ok('status C: links ok, no BROKEN', /alpha .* ok/.test(s0.out) && !/BROKEN/.test(s0.out), s0.out);

// A dangling link: a brief naming a sid no master lists.
brief('beta', 'dddddddd-0000-0000-0000-000000000004');
const bad = tm('status', '--sid', C); ok('dangling link prints BROKEN', /beta .*BROKEN/.test(bad.out) && /alpha .* ok/.test(bad.out), bad.out);
// A legacy file with only handedFrom still resolves.
fs.writeFileSync(path.join(md, 'eeeeeeee-0000-0000-0000-000000000005.json'), JSON.stringify({ sid: 'eeeeeeee-0000-0000-0000-000000000005', master: true, live: false, plan: null, delegates: [], handedFrom: 'ffffffff-0000-0000-0000-000000000006' }));
ok('legacy handedFrom resolves', tm('resolve', 'ffffffff-0000-0000-0000-000000000006').out.trim().startsWith('eeeeeeee'));
ok('unknown sid is not a master', tm('resolve', '99999999-0000-0000-0000-000000000009').code === 1);

// Reinject: a master gets its plan, not a delegate's brief that names its sid; others are unchanged.
const reinject = sid => run([bin('token-compact-reinject.js')], JSON.stringify({ source: 'compact', session_id: sid, transcript_path: '' }));
brief('delta', C); // newest brief with session=C, as in the field
const r1 = JSON.parse(reinject(C).out || '{}').hookSpecificOutput?.additionalContext || '';
ok('master reinject: plan doc + state line', /master rule one/.test(r1) && /\[master\] sid=cccccccc/.test(r1) && /delegates=alpha,beta/.test(r1), r1);
ok('master reinject: no delegate brief', !/body delta/.test(r1) && !/keep/.test(r1), r1);
const D = 'dddddddd-1111-0000-0000-000000000010';
fs.writeFileSync(path.join(ck, 'proj.solo.md'), `<!-- park: session=${D} topic=solo -->\n# solo\n\n## Next\n1. solo step\n`);
const r2 = JSON.parse(reinject(D).out || '{}').hookSpecificOutput?.additionalContext || '';
ok('non-master reinject unchanged', /solo step/.test(r2) && /Standing rules from checkpoint proj\.solo\.md/.test(r2) && !/\[master\]/.test(r2), r2);

// retire / warm: the delegate sid comes only from this master's records; a stub token-sessions.sh logs its calls.
const E = 'eeeeeeee-2222-0000-0000-000000000020', U = 'ffffffff-3333-0000-0000-000000000030';
const calls = path.join(home, 'calls.txt');
fs.writeFileSync(path.join(claude, 'token-sessions.sh'),
  `printf '%s|' "$@" >> '${calls.replace(/\\/g, '/')}'; echo >> '${calls.replace(/\\/g, '/')}'\n` +
  `[ "$1" = --json ] && echo '[{"sid":"${E}","name":"alpha","alive":1,"running":0,"context_k":80,"cache_left_min":40}]'\nexit 0\n`);
fs.mkdirSync(path.join(ck, 'reports'), { recursive: true });
fs.writeFileSync(path.join(ck, 'reports', 'proj.alpha.md'), `<!-- report: for=${A} sid=${E} topic=alpha status=done stop=met -->\n`);
fs.writeFileSync(path.join(ck, 'reports', 'proj.beta.md'), `<!-- report: for=${U} sid=${U} topic=beta status=done stop=met -->\n`); // another master's
let w = tm('warm', 'alpha', '--sid', C);
ok('warm: sid via a lineage report, verdict reuse', /eeeeeeee .*context_k=80 cache_left_min=40 {2}verdict=reuse/.test(w.out), w.out);
w = tm('warm', 'beta', '--sid', C);
ok('warm: a report for another master is not ours', /no sid recorded {2}verdict=new/.test(w.out), w.out);
fs.writeFileSync(calls, '');
w = tm('retire', 'beta', '--sid', C);
ok('retire: refuses an unrecorded sid, touches nothing', w.code === 1 && fs.readFileSync(calls, 'utf8') === '', w.out);
w = tm('retire', 'alpha', 'done here', '--sid', C);
ok('retire: extend 0 then block, slug dropped', w.code === 0 && fs.readFileSync(calls, 'utf8') === `--extend|${E}|0|\n--block|${E}|done here|\n` &&
  JSON.parse(fs.readFileSync(path.join(md, C + '.json'), 'utf8')).delegates.join() === 'beta', w.out + fs.readFileSync(calls, 'utf8'));

fs.rmSync(home, { recursive: true, force: true });
console.log(fails ? `${fails} failed` : 'all passed');
process.exit(fails ? 1 : 0);
