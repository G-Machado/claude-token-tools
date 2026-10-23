// PreToolUse hook (Bash|Edit|Write|MultiEdit|NotebookEdit): the CLAUDE.md git/Unity rules as hard checks.
//   deny  git commit without an explicit pathspec (` -- `)        CLAUDE.md Git
//   deny  --no-verify / commit -n / -c core.hooksPath on any git   CLAUDE.md Git
//   ask   git push --force / -f / --force-with-lease               hard to reverse
//   deny  dotnet build / msbuild inside a Unity project            stale generated .csproj/.sln
//   ask   Edit/Write on *.unity, *.prefab, *.asset                 Editor may hold the project (unity status first)
// Fails open: anything it cannot parse passes. Log: token-guard.log, ts sid tool rule decision (fires only).
const fs = require('fs'), path = require('path'), os = require('os');
const logf = path.join(os.homedir(), '.claude', 'token-guard.log');

function unityRoot(dir) {
  for (let d = dir, i = 0; d && i < 12; d = path.dirname(d), i++) {
    if (fs.existsSync(path.join(d, 'ProjectSettings', 'ProjectVersion.txt'))) return d;
    if (path.dirname(d) === d) break;
  }
  return null;
}

// Quoted text blanked to '_' at the same length: a -n, -- or ; inside a commit message never counts, and an index
// into the blanked command is still an index into the raw one.
function blank(c) {
  let out = '', q = null;
  for (let i = 0; i < c.length; i++) {
    const ch = c[i];
    if (q) {
      if (ch === q) { q = null; out += ch; }
      else if (q === '"' && ch === '\\' && i + 1 < c.length) { out += '__'; i++; }
      else out += '_';
    } else if (ch === '\\' && i + 1 < c.length) { out += ch + c[i + 1]; i++; }
    else { if (ch === '"' || ch === "'") q = ch; out += ch; }
  }
  return out;
}

const NOVERIFY = ['no-verify', 'deny', 'Hooks are never skipped (--no-verify / commit -n / core.hooksPath). Fix what the hook complains about, or ask the user.'];

// One check per command segment (split on unquoted ; & | ( ) newline backtick), so flags of a chained
// `head -n` or `rm -f` are never read as git's. Deny wins over ask.
function judgeGit(c) {
  const b = blank(c), seg = /[^;&|()\n`]+/g; let ask = null, m;
  while ((m = seg.exec(b))) {
    const s = m[0], raw = c.slice(m.index, m.index + s.length);
    // -C <dir> / -c <k=v> take a value; env assignments may precede git.
    const g = /^\s*(?:\w+=\S*\s+)*git\s+((?:(?:-[Cc]\s+\S+|-\S+)\s+)*)([\w-]+)/.exec(s);
    if (!g) continue;
    const rest = s.slice(g[0].length);
    if (/\s--no-verify\b/.test(s) || /core\.hookspath/i.test(raw.slice(0, g[0].length))) return NOVERIFY;
    if (g[2] === 'commit') {
      if (/(^|\s)-[a-ln-zA-Z]*n[a-ln-zA-Z]*(?=\s|$)/.test(rest)) return NOVERIFY;
      if (!/(^|\s)--(\s|$)/.test(rest))
        return ['commit-pathspec', 'deny', 'Commit with an explicit pathspec: git commit -m "..." -- <paths> (check git diff --cached --name-only first).'];
    }
    if (g[2] === 'push' && /(^|\s)(--force(-with-lease|-if-includes)?(=\S*)?|-[a-zA-Z]*f[a-zA-Z]*|\+\S+)(?=\s|$)/.test(rest))
      ask = ['push-force', 'ask', 'Force push rewrites the remote - confirm.'];
  }
  return ask;
}

function judge(p) {
  const tool = p.tool_name, inp = p.tool_input || {};
  const c = tool === 'Bash' && typeof inp.command === 'string' ? inp.command : '';
  const g = c && judgeGit(c); if (g) return g;
  if (c && /\b(dotnet\s+(build|msbuild)|msbuild)\b/.test(c) && unityRoot(p.cwd || process.cwd()))
    return ['unity-dotnet', 'deny', 'Unity project: never dotnet build/msbuild the generated .csproj/.sln. Use `unity command eval` / compile state, or `unity build`.'];
  const f = inp.file_path || inp.notebook_path;
  if (/^(Edit|Write|MultiEdit|NotebookEdit)$/.test(tool) && typeof f === 'string' && /\.(unity|prefab|asset)$/i.test(f))
    return ['unity-yaml', 'ask', 'Hand-editing Unity YAML: run `unity status` first - never while an Editor holds the project.'];
  return null;
}

let inp = '';
process.stdin.on('data', d => inp += d).on('end', () => {
  let p; try { p = JSON.parse(inp); } catch { return; }
  const r = judge(p); if (!r) return;
  const [rule, decision, reason] = r;
  try { fs.appendFileSync(logf, `${new Date().toISOString()} ${p.session_id || '-'} ${p.tool_name} ${rule} ${decision}\n`); } catch {}
  process.stdout.write(JSON.stringify({ hookSpecificOutput: {
    hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: '[token-guard] ' + reason } }));
});
