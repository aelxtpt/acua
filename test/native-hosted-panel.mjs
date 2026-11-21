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
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-hosted-panel-'));
const bundle = uniqueFixtureBundle('test.acua.owned-hosted-panel');
const app = path.join(directory, 'OwnedHostedPanel.app');
const binary = path.join(app, 'Contents/MacOS/OwnedHostedPanel');
fs.mkdirSync(path.dirname(binary), { recursive: true });
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>OwnedHostedPanel</string><key>CFBundleName</key><string>OwnedHostedPanel</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
for (const [source, destination, library] of [['HostedPanelFixture.swift', binary, true], ['WebFormAXOwners.swift', path.join(directory, 'ax-owners'), false]]) {
  execFileSync('swiftc', ['-O', ...(library ? ['-parse-as-library'] : []), '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test', source), '-o', destination], { stdio: 'inherit' });
}
execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
const { socket, service } = startNativeDesktop(directory, bundle);
const fixture = spawn(binary, [directory], { stdio: ['ignore', 'ignore', 'inherit'] });
const events = () => {
  const file = path.join(directory, 'events.jsonl');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
};
async function until(predicate, label) {
  const deadline = Date.now() + 15000;
  do { const value = await predicate(); if (value) return value; await sleep(40); } while (Date.now() < deadline);
  assert.fail(label);
}
async function command(value, expected = value) {
  const count = events().length, destination = path.join(directory, 'command');
  fs.writeFileSync(destination + '.pending', value); fs.renameSync(destination + '.pending', destination);
  return until(() => events().slice(count).find(event => event.event === expected), value);
}
async function request(name, fields = {}, clientType) {
  const body = Buffer.from(JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'ownedFixtureNativeRequest', params: {
    requestType: `ComputerUseIPCApp${name}Request`, request: { app: bundle, ...fields }, clientType,
  } }));
  const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  const client = net.createConnection({ path: socket });
  try {
    const reply = await new Promise((resolve, reject) => {
      let buffer = Buffer.alloc(0);
      client.on('connect', () => client.write(Buffer.concat([header, body])));
      client.on('data', chunk => { buffer = Buffer.concat([buffer, chunk]); if (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) resolve(JSON.parse(buffer.subarray(4, buffer.readUInt32LE(0) + 4).toString())); });
      client.on('error', reject); client.on('close', () => reject(new Error('Socket closed without a response')));
      client.setTimeout(20000, () => reject(new Error('Native request timed out')));
    });
    if (reply.error) { const error = new Error(JSON.stringify(reply.error)); error.code = reply.error.code; throw error; }
    return reply.result;
  } finally { client.destroy(); }
}
const action = value => request('PerformAction', { action: value }, 'node_repl');
const click = id => action({ click: { at: { elementID: { _0: id } }, clickCount: 1, mouseButton: 0 } });
const key = value => action({ pressKey: { _0: value } });
const owners = () => JSON.parse(execFileSync(path.join(directory, 'ax-owners'), [String(fixture.pid)], { encoding: 'utf8', timeout: 5000 }));
const find = (text, label) => {
  const line = text.split('\n').find(line => line.includes(label));
  assert.ok(line, `Missing ${label}: ${text}`);
  const match = line.match(/^\s*(\d+)\s/); assert.ok(match, line); return match[1];
};
async function capture(label) {
  const result = await request('GetAppSnapshot', { disableDiff: true });
  fs.writeFileSync(path.join(directory, `${label}.json`), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(directory, `${label}.txt`), result.appSnapshot.text);
  if (result.appSnapshot.screenshot) fs.copyFileSync(fileURLToPath(result.appSnapshot.screenshot.url), path.join(directory, `${label}.jpeg`));
  return result;
}
const pass = label => console.log(`PASS ${label}`);
try {
  await until(() => fs.existsSync(socket) && events().some(e => e.event === 'ready'), 'owned host window ready');
  const initial = await capture('initial');
  assert.equal(initial.app.pid, fixture.pid);
  const open = find(initial.appSnapshot.text, 'open-owned-chooser');
  pass('host window publishes an actionable owned chooser button');
  await click(open);
  await until(() => events().some(e => e.event === 'panel-requested'), 'native button opens chooser');
  let observed;
  await until(() => {
    observed = owners();
    return observed.some(e => e.role === 'AXButton' && [e.title, e.description].includes('Select owned file'));
  }, 'owned chooser accessibility controls published');
  fs.writeFileSync(path.join(directory, 'sheet-owners.json'), JSON.stringify(observed, null, 2));
  const remote = observed.filter(e => e.actualPID > 0 && e.actualPID !== fixture.pid && e.actualPIDStatus === 0);
  fs.writeFileSync(path.join(directory, 'remote-pids.json'), JSON.stringify([...new Set(remote.map(e => e.actualPID))]));
  const sheet = await capture('sheet');
  assert.match(sheet.appSnapshot.text, /Select owned file/);
  assert.ok(sheet.appSnapshot.screenshot);
  pass('native capture includes the system file chooser controls and a readable JPEG');
  assert.ok(remote.some(e => e.role === 'AXButton'), 'The platform did not publish remote chooser controls');
  pass('independent AX probe observes chooser buttons in a process separate from the owned host');
  const remoteCancel = remote.find(e => e.role === 'AXButton' && e.title === 'Cancel');
  assert.ok(remoteCancel.windowID > 0);
  assert.equal(remoteCancel.windowOwnerPID, remoteCancel.actualPID);
  assert.equal(remoteCancel.ordinaryWindowDescriptionAvailable, false);
  assert.ok(observed.some(e => e.role === 'AXSheet' && e.windowOwnerPID === fixture.pid && e.windowID !== remoteCancel.windowID));
  pass('the description API resolves the service backing window absent from ordinary enumeration');
  fs.writeFileSync(path.join(directory, 'before-escape-state.json'), JSON.stringify(await command('state')));
  const count = events().length;
  await key('Escape');
  fs.writeFileSync(path.join(directory, 'after-escape-state.json'), JSON.stringify(await command('state')));
  fs.writeFileSync(path.join(directory, 'after-escape-owners.json'), JSON.stringify(owners(), null, 2));
  const completed = await until(() => events().slice(count).find(e => e.event === 'panel-completed'), 'Escape cancels owned chooser');
  assert.equal(completed.accepted, false);
  assert.equal(completed.editor, 'OWNED HOST DOCUMENT — DO NOT EDIT');
  assert.equal(completed.decoy, 'DO NOT TOUCH HOSTED DECOY');
  pass('native Escape cancels the remote chooser without editing either host document');
  const returned = await capture('returned');
  assert.match(returned.appSnapshot.text, /host-editor/);
  assert.ok(!returned.appSnapshot.text.includes('CancelButton'));
  pass('closing the hosted sheet restores the earlier host window observation');
  await command('open-sheet', 'panel-requested');
  await until(() => owners().some(e => e.role === 'AXButton' && e.title === 'Cancel'), 'reopened remote cancel button');
  const reopened = await capture('reopened');
  const cancel = find(reopened.appSnapshot.text, 'CancelButton');
  let next = events().length;
  await action({ click: { at: { elementID: { _0: cancel } }, clickCount: 1, mouseButton: 0, duration: 0.02 } });
  const cancelled = await until(() => events().slice(next).find(e => e.event === 'panel-completed'), 'remote cancel button completes');
  assert.equal(cancelled.accepted, false);
  assert.equal(cancelled.editor, 'OWNED HOST DOCUMENT — DO NOT EDIT');
  assert.equal(cancelled.decoy, 'DO NOT TOUCH HOSTED DECOY');
  pass('held native mouse click reaches the remote Cancel button in its host-owned window');
  await command('open-panel', 'panel-requested');
  await until(() => owners().some(e => e.role === 'AXButton' && e.title === 'Cancel'), 'standalone chooser controls');
  const standalone = await capture('standalone');
  assert.match(standalone.appSnapshot.text, /Select owned file/);
  pass('standalone hosted chooser also publishes controls and a screenshot');
  await key('Command+Shift+g');
  await until(() => owners().some(e => e.role === 'AXComboBox' || (e.role === 'AXTextField' && e.title !== 'Search')), 'Go to Folder input');
  const goto = await capture('go-to-folder');
  fs.writeFileSync(path.join(directory, 'go-to-folder-owners.json'), JSON.stringify(owners(), null, 2));
  const selectedPath = path.join(directory, 'owned/owned-🙂-document.txt');
  await action({ type: { _0: selectedPath } });
  await until(() => owners().some(e => e.value === selectedPath), 'complete Unicode path in remote input');
  pass('native keyboard shortcut and Unicode typing reach the remote Go to Folder field');
  next = events().length;
  await key('Return');
  await until(() => owners().some(e => e.value === 'owned-🙂-document.txt' || e.title === 'owned-🙂-document.txt'), 'owned fixture file selected');
  const selected = await capture('selected-file');
  const choose = find(selected.appSnapshot.text, 'OKButton');
  await click(choose);
  const accepted = await until(() => events().slice(next).find(e => e.event === 'panel-completed'), 'owned file chooser completion');
  assert.equal(accepted.accepted, true); assert.equal(accepted.ownedSelection, true);
  assert.equal(accepted.editor, 'OWNED HOST DOCUMENT — DO NOT EDIT'); assert.equal(accepted.decoy, 'DO NOT TOUCH HOSTED DECOY');
  pass('native chooser selects only the owned Unicode-named temporary document');
} finally {
  if (fixture.exitCode === null && fixture.signalCode === null) {
    const destination = path.join(directory, 'command'); fs.writeFileSync(destination + '.pending', 'cancel-panel'); fs.renameSync(destination + '.pending', destination);
    await sleep(150);
  }
  await Promise.all([service, fixture].map(child => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    return new Promise(resolve => { const timer = setTimeout(() => child.kill('SIGKILL'), 3000); child.once('exit', () => { clearTimeout(timer); resolve(); }); child.kill('SIGTERM'); });
  }));
  console.log(`Owned hosted panel directory: ${directory}`);
}
