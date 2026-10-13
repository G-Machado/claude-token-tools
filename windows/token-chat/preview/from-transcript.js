// node preview/from-transcript.js <transcript.jsonl> <prompt HH:MM, UTC> <out.jsonl> [notail]: one real turn from a session transcript as
// stream-json for --preview. Run from windows/token-chat. Rows come only from stream_event blocks (whole assistant
// messages are ignored), and the tab stays on "starting claude..." without the initialize control_response first.
// notail stops after the last tool call, so the tool rows stay on screen instead of the final reply.
const fs = require('fs');
const [src, at, out] = process.argv.slice(2);
const L = fs.readFileSync(src, 'utf8').trim().split('\n').map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const isPrompt = j => j.type === 'user' && j.message && (typeof j.message.content === 'string' ||
  (Array.isArray(j.message.content) && !j.message.content.some(b => b.type === 'tool_result')));
const start = L.findIndex(j => isPrompt(j) && (j.timestamp || '').slice(11, 16) === at);
if (start < 0) throw new Error('no prompt at ' + at);
let end = L.findIndex((j, i) => i > start && isPrompt(j)); if (end < 0) end = L.length;
if (process.argv[5] === 'notail') { const k = L.slice(0, end).findLastIndex(j => j.type === 'assistant' && j.message.content.some(b => b.type === 'tool_use')); end = k + 2; }
const fx = fs.readFileSync('tests/TokenChat.Core.Tests/Fixtures/tools.jsonl', 'utf8').split(/\r?\n/).filter(Boolean).map(l => JSON.parse(l));
const sid = L[start].sessionId;
const init = { ...fx.find(j => j.type === 'system' && j.subtype === 'init'), session_id: sid, cwd: L[start].cwd };
const result = { ...fx.filter(j => j.type === 'result').pop(), session_id: sid };
const ctl = JSON.parse(fs.readFileSync('preview/asks.jsonl', 'utf8').split(/\r?\n/)[0]);
const rows = [ctl, init];
const se = event => rows.push({ type: 'stream_event', event, session_id: sid, parent_tool_use_id: null });
let msg = null, index = 0;
const close = () => { if (msg) { se({ type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: msg.usage }); se({ type: 'message_stop' }); } };
for (const j of L.slice(start + 1, end)) {
  if (j.type !== 'assistant' && j.type !== 'user') continue;
  if (j.type === 'assistant') {
    const m = j.message;
    if (!msg || msg.id !== m.id) { close(); msg = m; index = 0; se({ type: 'message_start', message: { id: m.id, model: m.model, usage: m.usage } }); }
    for (const b of m.content || []) {
      const start = b.type === 'tool_use' ? { type: 'tool_use', id: b.id, name: b.name, input: {} } : { type: b.type, [b.type]: '' };
      se({ type: 'content_block_start', index, content_block: start });
      const delta = b.type === 'text' ? { type: 'text_delta', text: b.text } : b.type === 'thinking' ? { type: 'thinking_delta', thinking: b.thinking }
        : b.type === 'tool_use' ? { type: 'input_json_delta', partial_json: JSON.stringify(b.input) } : null;
      if (delta) se({ type: 'content_block_delta', index, delta });
      se({ type: 'content_block_stop', index }); index++;
    }
  }
  rows.push({ type: j.type, message: j.message, parent_tool_use_id: null, session_id: sid, uuid: j.uuid, timestamp: j.timestamp });
}
close();
rows.push(result);
fs.writeFileSync(out, rows.map(r => JSON.stringify(r)).join('\n') + '\n');
console.log(`${rows.length} lines, ${rows.filter(r => r.type === 'assistant').length} assistant, prompt: ${JSON.stringify(L[start].message.content).slice(0, 80)}`);
