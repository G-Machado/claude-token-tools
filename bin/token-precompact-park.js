// PreCompact hook: "park, then compact". Before any compaction (manual, auto, idle - the docs list
// only manual|auto; idle is assumed to arrive as auto), write a mechanical checkpoint unless this
// session already has one newer than its last typed prompt (housekeeping commands like /compact or
// /effort don't count as prompts). Never blocks.
// Output: checkpoints/autopark/<project>-<sid8>.md - a subfolder, so token-sessions' "$proj".*.md
// glob and /unpark never list it as a topic - stamped autopark=<sid> (NOT session=). Reinject appends
// it as a supplement when it is newer than the real checkpoint; a FRESH real one deletes it.
// Content is transcript-derived and labelled assumed - no judgement; the last reply is quoted with
// "> " so its own "## " headings cannot open sections when reinject filters by heading.
// Log: token-precompact-park.log, raw quantities: ts sid trigger gap_min context prompts edits verdict.
const fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process');
const home = path.join(os.homedir(), '.claude');
const dir = path.join(home, 'checkpoints'), autodir = path.join(dir, 'autopark');
const logf = path.join(home, 'token-precompact-park.log');
const log = m => { try { fs.appendFileSync(logf, new Date().toISOString() + ' ' + m + '\n'); } catch {} };

// A typed slash command is all tags: keep it as "/name args" before stripping tag blocks.
const slash = s => { const n = s.match(/<command-name>([^<]*)<\/command-name>/); if (!n) return s;
  const a = s.match(/<command-args>([^<]*)<\/command-args>/); return n[1] + (a && a[1] ? ' ' + a[1] : ''); };
const clean = s => slash(s).replace(/<([a-z-]+)[^>]*>[\s\S]*?<\/\1>/g, '').replace(/\s+/g, ' ').trim();
const textOf = c => typeof c === 'string' ? c
  : Array.isArray(c) ? c.filter(b => b && b.type === 'text').map(b => b.text).join(' ') : '';
// Commands that start no work: they never make a checkpoint stale (the /compact that fires this hook is one).
const HOUSEKEEPING = /^\/(compact|park|effort|model|fast|tokens|context|cost|status|config|help)\b/;

let inp = '';
process.stdin.on('data', d => inp += d).on('end', () => {
  let p; try { p = JSON.parse(inp); } catch { log('ERROR bad stdin'); return; }
  const sid = p.session_id || '', trig = p.trigger || '?', cwd = p.cwd || process.cwd();
  let lines;
  try { lines = fs.readFileSync(p.transcript_path, 'utf8').split('\n'); }
  catch { log(`${sid} ${trig} ERROR transcript unreadable: ${p.transcript_path}`); return; }

  const prompts = [], edits = new Set(); let lastText = '', lastTs = 0, lastPromptTs = 0, ctx = 0;
  for (const l of lines) {
    let e; try { e = JSON.parse(l); } catch { continue; }
    const ts = Date.parse(e.timestamp || '') || 0; if (ts) lastTs = ts;
    const m = e.message; if (!m) continue;
    if (e.type === 'user' && !e.isMeta) {
      const t = clean(textOf(m.content));
      if (t && !HOUSEKEEPING.test(t)) { prompts.push(t.slice(0, 240)); if (ts) lastPromptTs = ts; }
    } else if (e.type === 'assistant' && Array.isArray(m.content)) {
      for (const b of m.content) {
        const f = b.input && (b.input.file_path || b.input.notebook_path);
        if (b.type === 'tool_use' && /^(Edit|Write|MultiEdit|NotebookEdit)$/.test(b.name) && f) edits.add(f);
        if (b.type === 'text' && b.text.trim()) lastText = b.text.trim();
      }
      const u = m.usage; if (u) ctx = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    }
  }
  const gap = lastTs ? Math.round((Date.now() - lastTs) / 60000) : -1;
  const raw = `${sid} ${trig} gap_min=${gap} context=${ctx} prompts=${prompts.length} edits=${edits.size}`;
  if (!prompts.length) { log(`${raw} ERROR 0 prompts collected`); return; }

  const proj = path.basename(cwd), name = `${proj}-${sid.slice(0, 8)}.md`, out_f = path.join(autodir, name);

  // A real checkpoint for this session, newer than the last typed prompt, already covers it - and
  // supersedes any autopark an earlier compaction left.
  try {
    for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.md'))) {
      const fp = path.join(dir, f);
      if (!fs.readFileSync(fp, 'utf8').slice(0, 200).includes('session=' + sid)) continue;
      if (fs.statSync(fp).mtimeMs >= lastPromptTs) {
        let gone = ''; try { fs.unlinkSync(out_f); gone = ` (deleted autopark/${name})`; } catch {}
        log(`${raw} FRESH ${f}${gone}`); return;
      }
    }
  } catch {}

  const git = a => { try { return cp.execSync('git ' + a, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; } };
  const branch = git('rev-parse --abbrev-ref HEAD'), head = git('log -1 --format="%h %s"');
  const dirty = git('status --porcelain').split('\n').filter(Boolean).length;
  const out = [
    `<!-- autopark=${sid} trigger=${trig} cwd=${cwd} -->`,
    `# ${proj} - autopark before ${trig} compaction - ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
    '', 'Mechanical: written by a hook, not by Claude. Everything below is assumed until re-checked.',
    '', '## Next (assumed: the last reply before compaction)', '',
    ...lastText.slice(0, 1500).split(/\r?\n/).map(l => '> ' + l),
    '', '## Goal (assumed: the last typed prompts, oldest first)', '',
    ...prompts.slice(-8).map(t => '- ' + t),
    '', '## Facts (mechanical)', '',
    `- git ${branch || '?'} @ ${head || '?'}, ${dirty} dirty`,
    `- context ${ctx}, idle ${gap} min before compaction`,
    ...[...edits].slice(-15).map(f => '- edited: ' + f),
  ];
  try { fs.mkdirSync(autodir, { recursive: true }); fs.writeFileSync(out_f, out.join('\n') + '\n'); }
  catch (err) { log(`${raw} ERROR write autopark/${name}: ${err.message}`); return; }
  log(`${raw} WROTE autopark/${name}`);
  process.stdout.write(JSON.stringify({ systemMessage: `pre-compact: autoparked checkpoints/autopark/${name}` }));
});
