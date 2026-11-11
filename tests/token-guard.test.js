// node tests/token-guard.test.js - feeds token-guard.js synthetic PreToolUse payloads; exit = failures.
const { execFileSync } = require('child_process'), path = require('path'), os = require('os'), fs = require('fs');
const guard = path.join(__dirname, '..', 'bin', 'token-guard.js');
const unity = fs.mkdtempSync(path.join(os.tmpdir(), 'guard-'));
fs.mkdirSync(path.join(unity, 'ProjectSettings')); fs.writeFileSync(path.join(unity, 'ProjectSettings', 'ProjectVersion.txt'), 'x');
const plain = os.tmpdir();
const bash = (command, cwd = plain) => ({ tool_name: 'Bash', tool_input: { command }, cwd, session_id: 'test' });
// a master session (token-master/master.json under the test HOME) and two lane files under _build/
const mbash = (command) => ({ tool_name: 'Bash', tool_input: { command }, cwd: plain, session_id: 'master' });
fs.mkdirSync(path.join(unity, '.claude', 'token-master'), { recursive: true });
fs.writeFileSync(path.join(unity, '.claude', 'token-master', 'master.json'), '{"sid":"master","master":true}');
const lanes = fs.mkdtempSync(path.join(os.tmpdir(), 'lanes-')); fs.mkdirSync(path.join(lanes, '_build'));
const big = path.join(lanes, '_build', 'review-big.md').replace(/\\/g, '/'), small = path.join(lanes, '_build', 'review-small.md').replace(/\\/g, '/');
fs.writeFileSync(big, '# lane\n'.repeat(2000)); fs.writeFileSync(small, '# lane\n## Summary\n| id | severity | title | where |\n');
const cases = [
  [bash('git commit -m "fix" -- a.cs b.cs'), null],
  [bash('git commit -m "fix a; b | c" -- a.cs'), null],
  [bash('git commit -m "fix"'), 'deny'],
  [bash('git add a && git commit -m "x"'), 'deny'],
  [bash('git -C repo commit -am "x"'), 'deny'],
  [bash('git commit --no-verify -m x -- a'), 'deny'],
  [bash('git commit -n -m x -- a'), 'deny'],
  [bash('git push --force origin main'), 'ask'],
  [bash('git push -f'), 'ask'],
  [bash('git push --force-with-lease'), 'ask'],
  [bash('git push origin main'), null],
  [bash('git log --oneline -- a.cs'), null],
  [bash('git diff --cached --name-only'), null],
  [bash('echo "git commit is fine to mention"'), null], // quoted: git must follow a separator or whitespace
  [bash('git -c core.hooksPath=x commit -m y'), 'deny'],
  [bash('git -c core.hooksPath=/dev/null commit -m x -- a'), 'deny'],
  [bash('git commit -m x -- a && head -n 5 log'), null],
  [bash('git commit -m "revert -- old"'), 'deny'],
  [bash('git commit -m "use -n" -- a'), null],
  [bash('git commit -an -m x -- a'), 'deny'],
  [bash('(cd r && git commit -m x)'), 'deny'],
  [bash('git push origin main && rm -f tmp'), null],
  [bash('git push origin +main'), 'ask'],
  [bash('git commit -m "$(cat <<\'EOF\'\nmsg; -n --\nEOF\n)" -- a'), null],
  [bash('dotnet build Assembly-CSharp.csproj', unity), 'deny'],
  [bash('dotnet build src/App', plain), null],
  [bash('dotnet test', unity), null],
  [{ tool_name: 'Edit', tool_input: { file_path: 'C:/p/Assets/Scenes/Main.unity' } }, 'ask'],
  [{ tool_name: 'Write', tool_input: { file_path: 'C:/p/Assets/X.prefab' } }, 'ask'],
  [{ tool_name: 'Edit', tool_input: { file_path: 'C:/p/Assets/X.cs' } }, null],
  // master read-guard (Bash side): token-master/<sid>.json marks the master; _build/ files over 8 KB are denied to cat/sed/head, not to grep
  [mbash(`cat ${big}`), 'deny'],
  [mbash(`sed -n 1,40p "${big}"`), 'deny'],
  [mbash(`grep -n '^## ' ${big}`), null],
  [mbash(`cat ${small}`), null],
  [bash(`cat ${big}`), null],                 // not a master: passes
];
let fail = 0;
for (const [p, want] of cases) {
  const out = execFileSync('node', [guard], { input: JSON.stringify(p), env: { ...process.env, USERPROFILE: unity, HOME: unity, CLAUDE_CONFIG_DIR: '' } }).toString();
  const got = out ? JSON.parse(out).hookSpecificOutput.permissionDecision : null;
  const ok = got === want; if (!ok) fail++;
  console.log(ok ? '  ok  ' : '  FAIL', String(got).padEnd(5), (p.tool_input.command || p.tool_input.file_path));
}
console.log(fail + ' failed'); process.exit(fail);
