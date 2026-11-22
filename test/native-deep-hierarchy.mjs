import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { requireNativeDesktop, startNativeDesktop } from './native-desktop-service.mjs';
import { uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
requireNativeDesktop();
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-deep-hierarchy-'));
const bundle = uniqueFixtureBundle('test.acua.owned-deep-hierarchy');
const app = path.join(directory, 'OwnedDeepHierarchy.app'), binary = path.join(app, 'Contents/MacOS/OwnedDeepHierarchy');
fs.mkdirSync(path.dirname(binary), { recursive: true });
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>OwnedDeepHierarchy</string><key>CFBundleName</key><string>OwnedDeepHierarchy</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/DeepHierarchyFixture.swift'), '-o', binary], { stdio: 'inherit' });
execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
// Requests name the fixture by path; see fixtureAppTarget.
const fixtureApp = fixtureAppTarget(app);
const { socket, service } = startNativeDesktop(directory, bundle, fixtureApp);
const fixture = spawn(binary, [directory], { stdio: ['ignore', 'ignore', 'inherit'] });
const events = () => { const f = path.join(directory, 'events.jsonl'); return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; };
async function until(predicate, label) {
  const deadline = Date.now() + 12000;
  do { const value = await predicate(); if (value) return value; await sleep(25); } while (Date.now() < deadline);
  assert.fail(label);
}
async function command(value, expected) {
  const count = events().length, f = path.join(directory, 'command');
  fs.writeFileSync(f + '.pending', value); fs.renameSync(f + '.pending', f);
  return until(() => events().slice(count).find(e => e.event === expected), value);
}
async function request(name, fields = {}, clientType) {
  const body = Buffer.from(JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'ownedFixtureNativeRequest', params: { requestType: `ComputerUseIPCApp${name}Request`, request: { app: fixtureApp, ...fields }, clientType } }));
  const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  const client = net.createConnection({ path: socket });
  try {
    const reply = await new Promise((resolve, reject) => {
      let buffer = Buffer.alloc(0);
      client.on('connect', () => client.write(Buffer.concat([header, body])));
      client.on('data', chunk => { buffer = Buffer.concat([buffer, chunk]); if (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) resolve(JSON.parse(buffer.subarray(4, buffer.readUInt32LE(0) + 4).toString())); });
      client.on('error', reject); client.on('close', () => reject(new Error('Closed without response')));
      client.setTimeout(40000, () => reject(new Error('Native deep hierarchy request timed out')));
    });
    if (reply.error) { const error = new Error(reply.error.message); error.code = reply.error.code; throw error; }
    return reply.result;
  } finally { client.destroy(); }
}
const results = [];
try {
  await until(() => fs.existsSync(socket) && events().some(e => e.event === 'ready'), 'owned deep fixture ready');
  for (const depth of [0, 1, 62, 63, 64, 65, 128, 197, 198, 199, 200, 201, 299, 300, 301, 384]) {
    await command(`depth:${depth}`, 'depth-ready');
    let errorCode = null, message, captured = false, count = 0;
    try {
      const shot = await request('GetAppSnapshot', { disableDiff: true });
      fs.writeFileSync(path.join(directory, `depth-${depth}.txt`), shot.appSnapshot.text);
      // The fixture contributes its root and AppKit's unknown wrapper in
      // addition to the virtual groups. The button's raw index-path depth is
      // group count + 3. Capture includes path depth 200 only.
      const line = shot.appSnapshot.text.split('\n').find(line => /^\s*\d+ button /.test(line) && line.includes('owned-deep-button'));
      captured = Boolean(line);
      assert.equal(captured, depth <= 197, `Capture depth boundary at ${depth}`);
      if (line) {
        const id = line.match(/^\s*(\d+)\s/)[1];
        await request('PerformAction', { action: { click: { at: { elementID: { _0: id } }, clickCount: 1, mouseButton: 0, duration: 0.01 } } }, 'node_repl');
        await until(() => events().find(e => e.event === 'button-action' && e.depth === depth), `button at depth ${depth}`);
      } else {
        assert.ok(shot.appSnapshot.text.includes('Owned depth 197'), 'Capture must retain the visible ancestor before pruning');
      }
    } catch (error) { errorCode = error.code ?? 'test'; message = error.message; }
    count = (await command('state', 'state')).count;
    const passed = errorCode === null && captured === (depth <= 197) && count === (captured ? 1 : 0);
    const result = { depth, captured, errorCode, message, count, passed }; results.push(result);
    console.log(`${passed ? 'PASS' : 'OBSERVED FAILURE'} native button at depth ${depth}: ${JSON.stringify(result)}`);
  }
  fs.writeFileSync(path.join(directory, 'outcomes.json'), JSON.stringify(results, null, 2));
  assert.ok(results.every(r => r.passed), JSON.stringify(results));
} finally {
  await Promise.all([service, fixture].map(child => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    return new Promise(resolve => { const timer = setTimeout(() => child.kill('SIGKILL'), 3000); child.once('exit', () => { clearTimeout(timer); resolve(); }); child.kill('SIGTERM'); });
  }));
  console.log(`Owned deep hierarchy directory: ${directory}`);
}
