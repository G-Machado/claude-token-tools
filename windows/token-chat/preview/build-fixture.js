// Builds asks.jsonl and question.jsonl for `TokenChat.App --preview preview/<file>`: one recorded turn each from the
// test fixtures, with the reply text and the AskUserQuestion input swapped for cases that exercise the open-asks bar
// (two, three and long options, a Recommended one, an ask with no options) and the question card (single, multi).
// Run: node preview/build-fixture.js
const fs = require('fs'), path = require('path');

const fixture = n => fs.readFileSync(path.join(__dirname, '../tests/TokenChat.Core.Tests/Fixtures', n + '.jsonl'), 'utf8')
  .split(/\r?\n/).filter(Boolean).map(l => JSON.parse(l));
const perm = fixture('perm'), tools = fixture('tools');
const expect = (o, what, ok) => { if (!ok) throw new Error(`fixture moved: expected ${what}, got ${JSON.stringify(o).slice(0, 120)}`); };

const reply = [
  'Both commits are in and the tree is clean:',
  '',
  '- `095ea98`: the Win32 focus rewrite',
  '- `8b48116`: step 2b, Parked Enter opens a TokenChat tab',
  '',
  'The classifier blocked the in-place edit, so the hunk was staged through the index instead.',
  '',
  '▶ 1 Start the preview dev mode? — go / later',
  '▶ 2 Keep the terminal fallback? — yes (Recommended) / drop it / only when TokenChat is missing',
  '▶ 3 Which branch for the release? — master / release-2026-10 / a new branch named after the topic slug',
  '▶ 4 Anything else before I build?',
].join('\n');

const questions = [
  {
    question: 'Where should the open-asks bar sit relative to the reply?', header: 'Layout', multiSelect: false,
    options: [
      { label: 'Under the reply (Recommended)', description: 'Asks stay next to the text that raised them.' },
      { label: 'Pinned above the input', description: 'Always visible, but detached from the reply.' },
      { label: 'Inline at each ask', description: 'Buttons inside the markdown, no separate bar.' },
    ],
  },
  {
    question: 'Which checks should run before every commit?', header: 'Checks', multiSelect: true,
    options: [
      { label: 'dotnet test', description: '78 tests, about a second.' },
      { label: 'PowerShell parse check', description: 'Every touched .ps1.' },
      { label: 'cmp against live', description: 'Repo copy against ~/.claude.' },
      { label: 'node --check', description: 'Inline scripts of generated pages.' },
    ],
  },
  {
    question: 'What should the dev flag be called?', header: 'Flag', multiSelect: false,
    options: [
      { label: '--preview', description: 'Matches the checkpoint.' },
      { label: '--fixture', description: 'Says what it reads.' },
    ],
  },
];

// Keep the first event of a run of deltas of one kind, rewritten; drop the rest.
const collapse = (lines, kind, rewrite) => {
  let done = false;
  return lines.flatMap(o => {
    const e = o.event;
    if (e?.type !== 'content_block_delta' || e.delta.type !== kind) return [o];
    if (done) return [];
    done = true;
    rewrite(e.delta);
    return [o];
  });
};

const handshake = perm.find(o => o.type === 'control_response');

// Turn 1, tools.jsonl 34-64: a reply ending in a ▶ block.
const turn1 = tools.slice(33, 64);
expect(turn1[0], 'init', turn1[0].subtype === 'init');
expect(turn1.at(-1), 'result', turn1.at(-1).type === 'result');

// Turn 2, perm.jsonl 81-100: an AskUserQuestion left pending (nothing after the request).
const turn2 = perm.slice(80, 100);
expect(turn2[0], 'init', turn2[0].subtype === 'init');
const ask = turn2.at(-1);
expect(ask, 'AskUserQuestion request', ask.request?.tool_name === 'AskUserQuestion');
ask.request.input.questions = questions;

const write = (name, turn) => {
  const out = [handshake, ...turn];
  fs.writeFileSync(path.join(__dirname, name), out.map(o => JSON.stringify(o)).join('\n') + '\n');
  console.log(`${out.length} lines -> preview/${name}`);
};
write('asks.jsonl', collapse(turn1, 'text_delta', d => { d.text = reply; }));
write('question.jsonl', collapse(turn2, 'input_json_delta', d => { d.partial_json = JSON.stringify({ questions }); }));
