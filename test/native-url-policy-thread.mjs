import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { requireNativeDesktop, startNativeDesktop } from './native-desktop-service.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
requireNativeDesktop();
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-native-automation-'));
const bundle = uniqueFixtureBundle('test.acua.native-tree-integration-fixture');
const app = path.join(directory, 'NativeAutomationFixture.app');
const targetPath = path.join(app, 'Contents/MacOS/NativeAutomationFixture');
fs.mkdirSync(path.dirname(targetPath), { recursive: true });
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>NativeAutomationFixture</string><key>CFBundleName</key><string>NativeAutomationFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
if (process.env.CUA_NATIVE_AUTOMATION_FIXTURE) fs.copyFileSync(process.env.CUA_NATIVE_AUTOMATION_FIXTURE, targetPath);
else execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/InputFixture.swift'), '-o', targetPath], { stdio: 'inherit' });
execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
const { socket, service } = startNativeDesktop(directory, bundle, 'url-policy');
const fixtures = [];
async function waitFor(predicate, label) {
  for (let i = 0; i < 160; i++) {
    if (predicate()) return;
    await sleep(40);
  }
  assert.fail(label);
}
async function openTarget(label) {
  const session = path.join(directory, label);
  fs.mkdirSync(session);
  const app = spawn(targetPath, [session], { stdio: ['ignore', 'ignore', 'inherit'] });
  fixtures.push(app);
  const events = path.join(session, 'events.jsonl');
  await waitFor(() => fs.existsSync(events) && fs.readFileSync(events, 'utf8').includes('"ready"'), 'window ready');
  return app;
}
async function request(name, fields = {}, type) {
  const body = Buffer.from(JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'ownedFixtureNativeRequest',
    params: { requestType: `ComputerUseIPCApp${name}Request`, request: { app: bundle, ...fields }, clientType: type } }));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  const client = net.createConnection({ path: socket });
  try {
    const response = await new Promise((resolve, reject) => {
      let buffer = Buffer.alloc(0);
      client.on('connect', () => client.write(Buffer.concat([header, body])));
      client.on('data', chunk => {
        buffer = Buffer.concat([buffer, chunk]);
        if (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) {
          resolve(JSON.parse(buffer.subarray(4).toString('utf8')));
        }
      });
      client.on('error', reject);
      client.on('close', () => reject(new Error('Socket closed without a response')));
      client.setTimeout(15000, () => reject(new Error('Native dispatch timed out')));
    });
    if (response.error) { const error = new Error(JSON.stringify(response.error)); error.code = response.error.code; throw error; }
    return response.result;
  } finally {
    client.destroy();
  }
}
function jpeg(reply, target) {
  assert.equal(reply.app.pid, target.pid);
  const result = reply.appSnapshot.screenshot;
  assert.equal(result.mimeType, 'image/jpeg');
  assert.equal(reply.appSnapshot.coordinateSpace, undefined);
  const file = fileURLToPath(result.url);
  const parent = path.relative(path.join(directory, 'shots'), path.dirname(file));
  assert.match(parent, /^(?:[1-9]\d*)?$/, 'Capture must stay in its configured root or a numeric collision directory');
  assert.equal(fs.readFileSync(file).subarray(0, 2).toString('hex'), 'ffd8');
  return file;
}
try {
  await waitFor(() => fs.existsSync(socket), 'service socket');
  const target = await openTarget('first');
  const result = await request('GetAppSnapshot', { disableDiff: true });
  jpeg(result, target);
  assert.match(result.appSnapshot.text, /input-editor/);
  console.log('PASS native capture receives an asynchronous main-actor policy response without blocking the UI thread');

} finally {
  for (const child of [service, ...fixtures]) child.kill('SIGTERM');
  console.log(`Owned fixture directory: ${directory}`);
}
