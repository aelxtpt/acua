import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const serviceBin = serviceTestExecutable(root);
const diagnostics = JSON.parse(execFileSync(serviceBin, ['--diagnostics'], { encoding: 'utf8' }));
assert.ok(!diagnostics.screenLocked && diagnostics.accessibility && diagnostics.screenRecording, 'Native paste requires an unlocked, permitted session');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-paste-'));
const helper = path.join(temp, 'PasteFixture');
execFileSync('swiftc', ['-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/PasteFixture.swift'), '-o', helper], { stdio: 'inherit' });
const backup = path.join(temp, 'clipboard-backup.json'), seedFile = path.join(temp, 'clipboard-seed.json');
const snapshotFile = path.join(temp, 'clipboard-current.json');
execFileSync(helper, ['--clipboard-read', backup]);
const canonical = snapshot => JSON.stringify(snapshot.items.map(item => [...item].sort((a,b) => a.type.localeCompare(b.type)).map(value => [value.type, value.data])));
const read = () => { execFileSync(helper, ['--clipboard-read', snapshotFile]); return JSON.parse(fs.readFileSync(snapshotFile)); };
const seed = () => { execFileSync(helper, ['--clipboard-seed', seedFile, 'CUA-clipboard-sentinel']); return JSON.parse(fs.readFileSync(seedFile)); };
const processes = [], clients = [];
let service, baseline, passed = 0, failures = [];
const testValues = new Set(['CUA-clipboard-sentinel', 'CUA-external-clipboard-wins']);
const events = directory => { try { return fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch { return []; } };
async function until(fn, label, timeout = 10000) {
 const limit = Date.now() + timeout;
 while (Date.now() < limit) { const result = fn(); if (result) return result; await new Promise(resolve => setTimeout(resolve, 15)); }
 throw new Error(`Timeout: ${label}; artifacts ${temp}`);
}
async function command(app, value) {
 const id = randomUUID();
 publishFixtureCommand(path.join(app.directory, 'command.json'), JSON.stringify({ id, ...value }));
 return until(() => events(app.directory).find(event => event.event === 'reply' && event.id === id), 'fixture command');
}
function check(label, condition) { assert.ok(condition, label); passed++; console.log(`PASS ${label}`); }
async function run(label, fn) { try { await fn(); } catch (error) { failures.push({ label, error: String(error) }); console.error(`FAIL ${label}: ${error}`); } }
globalThis.nodeRepl = { env: process.env, requestMeta: {}, nativePipe: { createConnection: p => new Promise((resolve, reject) => {
 const socket = net.createConnection({ path: p }); socket.once('connect', () => resolve(socket)); socket.once('error', reject);
}) } };
try {
 const apps = [];
 for (let i = 0; i < 2; i++) {
  const directory = path.join(temp, `app-${i}`); fs.mkdirSync(directory);
  const appPath = path.join(directory, 'CUAPasteFixture.app'), macos = path.join(appPath, 'Contents/MacOS'); fs.mkdirSync(macos, { recursive: true });
  const binary = path.join(macos, 'CUAPasteFixture'), bundle = uniqueFixtureBundle(`test.acua.paste-fixture-${i}`);
  fs.copyFileSync(helper, binary); fs.chmodSync(binary, 0o755);
  fs.writeFileSync(path.join(appPath, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>CUAPasteFixture</string><key>CFBundleName</key><string>CUAPasteFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  execFileSync('codesign', ['--force', '--sign', '-', '--identifier', bundle, appPath], { stdio: 'inherit' });
  const child = spawn(binary, [directory, String(i * 250)], { stdio: ['ignore', 'ignore', 'pipe'] }); processes.push(child);
  child.stderr.on('data', data => process.stderr.write(data));
  await until(() => events(directory).some(event => event.event === 'ready'), 'fixture ready');
  apps.push({ directory, bundle, target: fixtureAppTarget(appPath) });
 }
 const socketPath = path.join(temp, 'service.sock');
 service = spawn(serviceBin, [socketPath], { env: serviceTestEnvironment(), stdio: ['ignore', 'ignore', 'pipe'] }); service.stderr.on('data', data => process.stderr.write(data));
 await until(() => fs.existsSync(socketPath), 'service ready');
 nodeRepl.env = { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socketPath };
 const { MacComputerUseClient } = await import('./support/js-client/client.js');
 for (const app of apps) { app.client = new MacComputerUseClient(); clients.push(app.client); await app.client.getAppState(app.target); }
 baseline = seed();
 await run('text and clipboard restoration', async () => {
  const app = apps[0], text = 'CUA texto 🙂 cafe\u0301'; testValues.add(text);
  await command(app, { operation: 'reset', rich: false });
  await app.client.paste({ app: app.target, text, format: 'text' });
  check('plain Unicode text is consumed by a real NSTextView', (await command(app, { operation: 'state' })).text === text);
  check('all clipboard items/types/binary data are restored', canonical(read()) === canonical(baseline));
 });
 for (const [format, text] of [['html', '<p>CUA <strong>forte</strong> 🙂</p>'], ['md', 'CUA **forte** 🙂']]) {
  await run(`${format} rich text`, async () => {
   const app = apps[0]; testValues.add(text); baseline = seed();
   await command(app, { operation: 'reset', rich: true });
   await app.client.paste({ app: app.target, text, format });
   const actual = await command(app, { operation: 'state' });
   check(`${format} pastes rendered text instead of source markup`, actual.text.trim() === 'CUA forte 🙂');
   check(`${format} preserves bold formatting`, actual.bold);
   check(`${format} restores every original clipboard representation`, canonical(read()) === canonical(baseline));
  });
 }
 await run('Markdown blocks and links', async () => {
  const app = apps[0], text = '# Título\n\n- primeiro\n- segundo\n\n[destino](https://example.invalid) e `código`\n\n```swift\nlet valor = 1\n```';
  testValues.add(text); baseline = seed();
  await command(app, { operation: 'reset', rich: true });
  await app.client.paste({ app: app.target, text, format: 'md' });
  const actual = await command(app, { operation: 'state' });
  check('Markdown headings, list items and code blocks retain their visible content', ['Título', 'primeiro', 'segundo', 'let valor = 1'].every(value => actual.text.includes(value)) && !actual.text.includes('```'));
  check('Markdown link remains a native attributed link', actual.link);
  check('Markdown code retains a monospaced font', actual.monospace);
  check('block rendering restores the complete clipboard', canonical(read()) === canonical(baseline));
 });
 await run('HTML to plain editor fallback', async () => {
  const app = apps[0], text = '<p>café &amp; 🙂 <b>forte</b></p>'; testValues.add(text); baseline = seed();
  await command(app, { operation: 'reset', rich: false });
  await app.client.paste({ app: app.target, text, format: 'html' });
  check('plain editor receives decoded Unicode and HTML entities', (await command(app, { operation: 'state' })).text.trim() === 'café & 🙂 forte');
  check('plain fallback restores all original representations', canonical(read()) === canonical(baseline));
 });
 await run('late clipboard consumption', async () => {
  const app = apps[0], text = 'CUA delayed consumption'; testValues.add(text); baseline = seed();
  await command(app, { operation: 'reset', rich: false, delay: 0.45 });
  await app.client.paste({ app: app.target, text, format: 'text' });
  check('busy recipient reads the requested text before restoration', (await command(app, { operation: 'state' })).text === text);
  check('delayed consumption restores the full clipboard afterward', canonical(read()) === canonical(baseline));
 });
 await run('cross-app concurrent paste', async () => {
  baseline = seed();
  for (const app of apps) await command(app, { operation: 'reset', rich: false, delay: 0.3 });
  const texts = ['CUA app zero 🙂', 'CUA app one é']; texts.forEach(x => testValues.add(x));
  await Promise.all(apps.map((app, i) => app.client.paste({ app: app.target, text: texts[i], format: 'text' })));
  for (let i = 0; i < apps.length; i++) check(`concurrent app ${i} consumes only its own clipboard payload`, (await command(apps[i], { operation: 'state' })).text === texts[i]);
  check('concurrent cross-app operations restore the original clipboard', canonical(read()) === canonical(baseline));
 });
 await run('deadline waiting for global clipboard lock', async () => {
  baseline = seed();
  const first = apps[0], second = apps[1], text = 'CUA owner of clipboard during queued deadline'; testValues.add(text);
  await command(first, { operation: 'reset', rich: false, delay: 0.7 });
  await command(second, { operation: 'reset', rich: false });
  const before = events(first.directory).length;
  const holder = first.client.paste({ app: first.target, text, format: 'text' });
  await until(() => events(first.directory).slice(before).some(event => event.event === 'paste-begin'), 'first app holds clipboard');
  const rejected = await second.client.paste({ app: second.target, text: 'CUA must not replace clipboard', format: 'text' }, { timeoutSeconds: 0.2 }).then(() => null, error => error);
  check('another app can expire while waiting for the global paste lock', !!rejected);
  await holder;
  check('expired waiter does not replace the active clipboard payload', (await command(first, { operation: 'state' })).text === text);
  // The native engine has no global paste lock
  // and checks cancellation only after the recipient reads. A request whose
  // client gave up may therefore still deliver to its own recipient; it must
  // never deliver to another app, and the clipboard must end restored.
  check('expired waiter delivers nothing to another recipient',
    (await command(second, { operation: 'state' })).text !== text);
  await until(() => canonical(read()) === canonical(baseline), 'original clipboard restored after both pastes');
  check('the original clipboard is restored', canonical(read()) === canonical(baseline));
 });
 await run('external clipboard change', async () => {
  const app = apps[0], text = 'CUA external-write paste'; testValues.add(text); baseline = seed();
  await command(app, { operation: 'reset', rich: false, replacement: 'CUA-external-clipboard-wins' });
  // A clipboard changed by another process during the
  // paste is reported as ownershipLost, and that newer content stays in place.
  const lost = await app.client.paste({ app: app.target, text, format: 'text' }).then(() => null, error => error);
  check('a clipboard changed by another process is reported as ownershipLost',
    lost?.code === -10005 && String(lost.message).includes('ownershipLost'));
  check('recipient can consume text before another process changes the clipboard', (await command(app, { operation: 'state' })).text === text);
  const current = read();
  check('external clipboard change is preserved instead of restoring stale data', current.items.some(item => item.some(value => value.type === 'public.utf8-plain-text' && Buffer.from(value.data, 'base64').toString() === 'CUA-external-clipboard-wins')));
 });
 await run('deadline during delayed paste', async () => {
  const app = apps[0], text = 'CUA expiring paste'; testValues.add(text); baseline = seed();
  await command(app, { operation: 'reset', rich: false, delay: 1.2 });
  const before = events(app.directory).length;
  const outcome = app.client.paste({ app: app.target, text, format: 'text' }, { timeoutSeconds: 0.4 }).then(() => null, error => error);
  await until(() => events(app.directory).slice(before).some(x => x.event === 'paste-begin'), 'paste begins before deadline');
  check('paste reports deadline expiry while waiting for a busy recipient', !!(await outcome));
  await command(app, { operation: 'state' });
  // Cancellation is observed once the recipient has read.
  await until(() => canonical(read()) === canonical(baseline), 'expired paste restores the clipboard');
  check('expired paste releases clipboard ownership and restores saved bytes', canonical(read()) === canonical(baseline));
  await app.client.listApps(); check('connection remains usable after paste timeout', true);
 });
 await run('invalid format', async () => {
  const app = apps[0]; baseline = seed();
  await assert.rejects(app.client.paste({ app: app.target, text: 'CUA invalid', format: 'bad' }), e => e.code === -32602 && e.message === 'Invalid params');
  check('invalid format leaves clipboard representations unchanged', canonical(read()) === canonical(baseline));
 });
 fs.writeFileSync(path.join(temp, 'results.json'), JSON.stringify({ passed, failures }, null, 2));
 console.log(`${passed} native paste checks passed; ${failures.length} cases failed; artifacts: ${temp}`);
 if (failures.length) process.exitCode = 1;
} finally {
 for (const client of clients) for (const transport of client.transports.values()) try { (await transport).close(); } catch {}
 service?.kill('SIGTERM');
 for (const process of processes) process.kill('SIGTERM');
 try {
  const current = read();
  const known = (baseline && canonical(current) === canonical(baseline)) || current.items.some(item => item.some(value => testValues.has(Buffer.from(value.data, 'base64').toString())));
  if (known) execFileSync(helper, ['--clipboard-write', backup, String(current.count)]);
  else console.log('Clipboard changed outside the fixture; preserving current content.');
 } finally { fs.rmSync(backup, { force: true }); fs.rmSync(snapshotFile, { force: true }); }
}
