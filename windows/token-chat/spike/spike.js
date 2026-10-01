// Throwaway spike: drive a hidden `claude -p` over stream-json, record every
// stdout line as a fixture, print a compact summary. node spike.js <profile>
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const profile = process.argv[2] || 'full';
const DIR = __dirname;
const CWD = path.resolve(__dirname, '..', '..', '..');
const TOOLS = 'Read,Edit,Write,Bash,Grep,Glob';
const SLIM = 'You are a coding assistant working in a local repository on Windows. ' +
  'Use the tools to read and change files. Be concise.';

const base = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json',
  '--verbose', '--include-partial-messages', '--include-hook-events',
  '--permission-prompts', 'host', '--permission-mode', 'manual'];
const profiles = {
  full: ['--add-dir', DIR],
  tools: ['--tools', TOOLS + ',AskUserQuestion', '--strict-mcp-config'],
  noskills: ['--tools', TOOLS, '--strict-mcp-config', '--disable-slash-commands'],
  perm: ['--tools', TOOLS + ',AskUserQuestion', '--strict-mcp-config', '--add-dir', DIR, '--permission-prompt-tool', 'stdio'],
  slim: ['--tools', TOOLS, '--strict-mcp-config', '--disable-slash-commands', '--system-prompt', SLIM],
};

function png16(r, g, b) {
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(48).map((_, i) => [r, g, b][i % 3])]);
  const raw = Buffer.concat(Array(16).fill(row));
  const chunk = (t, d) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(d.length);
    const td = Buffer.concat([Buffer.from(t), d]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(16, 0); ihdr.writeUInt32BE(16, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

const steps = profile === 'perm' ? [
  { name: 'perm', content: `Use the Write tool to create the file ${DIR.split('\\').join('/')}/spike-perm.txt containing the word hi. Nothing else.` },
  { name: 'ask', content: 'Use the AskUserQuestion tool to ask me whether I prefer red or blue, then reply with my answer in one word.' },
] : profile === 'full' ? [{ name: 'floor', content: 'Reply with just: ok' }] : [
  { name: 'context', content: '/context' },
  { name: 'floor', content: 'Reply with just: ok' },
];
if (profile === 'tools') steps.push({ name: 'ask', content: 'Use the AskUserQuestion tool to ask me whether I prefer red or blue, then reply with my answer in one word.' });
if (profile === 'full') steps.push(
  { name: 'perm', content: `Use the Write tool to create the file ${DIR.replace(/\\/g, '/')}/spike-perm.txt containing the word hi. Nothing else.` },
  { name: 'interrupt', content: 'Count from 1 to 300, one number per line, no other text.', interrupt: true },
  { name: 'compact', content: '/compact' },
  { name: 'after', content: 'Reply with just: ok' },
);

const fixture = path.join(DIR, `fixture-${profile}.jsonl`);
fs.writeFileSync(fixture, '');
const EXE = path.join(process.env.APPDATA, 'npm', 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe');
const child = spawn(EXE, [...base, ...profiles[profile]], { cwd: CWD, shell: false });
child.stderr.on('data', d => fs.appendFileSync(path.join(DIR, `stderr-${profile}.txt`), d));

let waiter = null, cur = null, buf = '';
const types = {};
const send = o => child.stdin.write(JSON.stringify(o) + '\n');
const short = s => String(s ?? '').replace(/\s+/g, ' ').slice(0, 220);

child.stdout.on('data', d => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    fs.appendFileSync(fixture, line + '\n');
    let m; try { m = JSON.parse(line); } catch { console.log('NONJSON', short(line)); continue; }
    const key = m.type + (m.subtype ? ':' + m.subtype : '') + (m.event?.type ? ':' + m.event.type : '');
    types[key] = (types[key] || 0) + 1;
    if (m.type === 'system' && m.subtype === 'init' && !types.__init) { types.__init = 1;
      console.log('INIT model=%s perm=%s tools=%d mcp=%j', m.model, m.permissionMode,
        (m.tools || []).length, (m.mcp_servers || []).map(s => s.name + ':' + s.status));
      console.log('  tools:', (m.tools || []).join(' '));
      
    }
    if (m.type === 'system' && !/^(init|hook_|status|thinking_tokens|commands_changed)/.test(m.subtype)) console.log('  SYS', m.subtype, short(JSON.stringify(m)).slice(0, 160));
    if (m.type === 'assistant' && m.message?.usage && cur) {
      const u = m.message.usage;
      cur.usage.push([u.input_tokens, u.cache_creation_input_tokens, u.cache_read_input_tokens, u.output_tokens]);
      for (const b of m.message.content || []) if (b.type === 'tool_use') cur.tools.push(b.name);
    }
    if (m.type === 'stream_event' && cur?.interrupt && !cur.sentInt && m.event?.type === 'content_block_delta') {
      cur.sentInt = true;
      send({ type: 'control_request', request_id: 'int1', request: { subtype: 'interrupt' } });
      console.log('  -> interrupt sent');
    }
    if (m.type === 'control_request') {
      const r = m.request || {};
      console.log('  CTRL_REQ', r.subtype, r.tool_name || '', short(JSON.stringify(r.input || {})).slice(0, 160));
      console.log('    req keys:', Object.keys(r).join(' '));
      let response;
      if (r.subtype === 'can_use_tool' && r.tool_name === 'Write' && String(r.input?.file_path || '').includes('spike-perm')) {
        response = { behavior: 'allow', updatedInput: r.input };
      } else if (r.subtype === 'can_use_tool' && r.tool_name === 'AskUserQuestion') {
        const answers = {};
        for (const q of r.input?.questions || []) answers[q.question] = q.options?.[1]?.label || q.options?.[0]?.label;
        response = { behavior: 'allow', updatedInput: { ...r.input, answers } };
      } else {
        response = { behavior: 'deny', message: 'denied by spike' };
      }
      send({ type: 'control_response', response: { subtype: 'success', request_id: m.request_id, response } });
    }
    if (m.type === 'control_response') console.log('  CTRL_RESP', short(JSON.stringify(m)).slice(0, 160));
    if (m.type === 'result' && waiter) {
      const u = m.usage || {};
      cur.result = { sub: m.subtype, err: m.is_error, text: short(m.result), turns: m.num_turns,
        usage: [u.input_tokens, u.cache_creation_input_tokens, u.cache_read_input_tokens, u.output_tokens] };
      const w = waiter; waiter = null; w();
    }
  }
});

(async () => {
  if (profile === 'perm') { send({ type: 'control_request', request_id: 'init1', request: { subtype: 'initialize', hooks: null } }); await new Promise(r => setTimeout(r, 4000)); }
  for (const s of steps) {
    cur = { ...s, usage: [], tools: [] };
    const t0 = Date.now();
    send({ type: 'user', message: { role: 'user', content: s.content }, parent_tool_use_id: null });
    const ok = await new Promise(res => {
      waiter = () => res(true);
      setTimeout(() => { if (waiter) { waiter = null; res(false); } }, 180000);
    });
    console.log(`STEP ${s.name} ${ok ? '' : 'TIMEOUT '}${((Date.now() - t0) / 1000).toFixed(1)}s tools=[${cur.tools}]`);
    console.log('  usage per request [in, write, read, out]:', JSON.stringify(cur.usage));
    if (cur.result) console.log('  result:', JSON.stringify(cur.result));
  }
  child.stdin.end();
  await new Promise(r => child.on('exit', r));
  console.log('EVENT TYPES', JSON.stringify(types));
})();
