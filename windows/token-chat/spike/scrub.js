// Turn the git-ignored spike recordings (*.raw.jsonl) into committable test fixtures:
// replace every email, the local username (in every path form, including the
// C--Users-<name>- project slug and partial_json fragments) and the hostname.
// The identity comes from the OS, never from this file. node scrub.js
const fs = require('fs');
const os = require('os');
const path = require('path');

const OUT = path.resolve(__dirname, '..', 'tests', 'TokenChat.Core.Tests', 'Fixtures');
const user = os.userInfo().username;
const host = os.hostname();
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const rules = [
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z][A-Za-z.]*/g, 'user@example.com'],
  [new RegExp(esc(user), 'gi'), 'user'],
  [new RegExp(esc(host), 'gi'), 'host'],
];
// Anything still matching after the rules is a failure, not a warning.
const residue = [new RegExp(esc(user), 'i'), new RegExp(esc(host), 'i'), /@(?!example\.com)[A-Za-z0-9-]+\.(com|net|org|io)\b/];

const inputs = fs.readdirSync(__dirname).filter(f => f.endsWith('.raw.jsonl'));
if (!inputs.length) throw new Error('no *.raw.jsonl recordings in ' + __dirname);
fs.mkdirSync(OUT, { recursive: true });

let failed = false;
for (const f of inputs) {
  let text = fs.readFileSync(path.join(__dirname, f), 'utf8');
  const counts = rules.map(([re, to]) => { let n = 0; text = text.replace(re, () => (n++, to)); return n; });
  const lines = text.split(/\r?\n/).filter(l => l.trim());
  lines.forEach((l, i) => { try { JSON.parse(l); } catch { failed = true; console.error(`${f}:${i + 1} no longer parses`); } });
  for (const re of residue) if (re.test(text)) { failed = true; console.error(`${f}: residue matches ${re}`); }
  if (!lines.length) { failed = true; console.error(`${f}: empty`); }
  const dest = path.join(OUT, f.replace('.raw.jsonl', '.jsonl'));
  fs.writeFileSync(dest, lines.join('\n') + '\n');
  console.log(`${f} -> ${path.relative(process.cwd(), dest)}  lines=${lines.length} email=${counts[0]} user=${counts[1]} host=${counts[2]}`);
}
if (failed) { console.error('scrub FAILED: fixtures above are not safe to commit'); process.exit(1); }
