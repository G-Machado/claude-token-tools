// Effort trial: alternate the default effort for claude-opus-5-5 by day, so a few weeks of transcripts compare
// high against medium on a comparable task mix. Day 0 (2026-10-04) and every even day: high; odd days: medium.
// (Until 2026-10-04 the arms were xhigh / high; the user made high the default and medium the challenger.)
// Writes modelSettings["claude-opus-5-5"].effortLevel in ~/.claude/settings.json only when it differs.
// Run by the EffortTrial scheduled task (effort-trial-install.ps1) at 00:01 and at logon. --off restores high.
const fs = require('fs'), path = require('path'), os = require('os');
const file = path.join(os.homedir(), '.claude', 'settings.json');
const log = m => fs.appendFileSync(path.join(os.homedir(), '.claude', 'effort-trial.log'), `${new Date().toISOString()}\t${m}\n`);
const MODEL = 'claude-opus-5-5', START = new Date(2026, 9, 4);

const now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
const day = Math.round((today - START) / 864e5);
const want = process.argv.includes('--off') || day % 2 === 0 ? 'high' : 'medium';

const raw = fs.readFileSync(file, 'utf8');
const s = JSON.parse(raw);
const ms = (s.modelSettings ??= {}), m = (ms[MODEL] ??= {});
if (m.effortLevel === want) { log(`day ${day}: ${MODEL} already ${want}`); process.exit(0); }
const was = m.effortLevel;
m.effortLevel = want;
fs.writeFileSync(file + '.effort-trial.bak', raw);
fs.writeFileSync(file, JSON.stringify(s, null, 2) + '\n');
log(`day ${day}: ${MODEL} ${was} -> ${want}`);
