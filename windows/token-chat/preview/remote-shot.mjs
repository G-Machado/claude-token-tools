// Screenshot the TokenChat remote page in headless Edge, paired via an existing cookie.
// usage: node remote-shot.mjs <out.png> [width] [height]
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';

const out = process.argv[2], W = +(process.argv[3] || 1280), H = +(process.argv[4] || 800);
const token = readFileSync(join(homedir(), '.claude', 'tokenchat-remote-tokens'), 'utf8').split(/\r?\n/).find(Boolean);
if (!token) throw new Error('no paired token');
const edge = spawn('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  ['--headless=new', '--remote-debugging-port=9333', `--window-size=${W},${H}`, '--user-data-dir=' + mkdtempSync(join(tmpdir(), 'edge-')), 'about:blank'],
  { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let targets;
for (let i = 0; i < 50 && !targets; i++) { await sleep(200); try { targets = await (await fetch('http://127.0.0.1:9333/json')).json(); } catch {} }
const page = targets.find(t => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const wait = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (wait.has(m.id)) { wait.get(m.id)(m.result); wait.delete(m.id); } };
const cdp = (method, params = {}) => new Promise(r => { wait.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
await cdp('Network.enable');
await cdp('Network.setCookie', { name: 'tokenchat', value: token, domain: '127.0.0.1', path: '/' });
await cdp('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
await cdp('Page.enable');
await cdp('Page.navigate', { url: 'http://127.0.0.1:8765/' });
await sleep(3500);
const shot = await cdp('Page.captureScreenshot', { format: 'png' });
writeFileSync(out, Buffer.from(shot.data, 'base64'));
console.log('saved', out);
ws.close(); edge.kill();
process.exit(0);
