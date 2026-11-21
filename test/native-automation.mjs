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
const pressErrorProbe = process.env.CUA_NATIVE_PRESS_ERROR_PROBE === '1';
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
const { socket, service } = startNativeDesktop(directory, bundle, pressErrorProbe ? 'press' : 'standard');
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
  const app = spawn(targetPath, [session], { env: { ...process.env, ...(pressErrorProbe ? { CUA_NATIVE_FAULT_BUTTONS: '1' } : {}) }, stdio: ['ignore', 'ignore', 'inherit'] });
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
const events = () => {
  const file = path.join(directory, 'first', 'events.jsonl');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
};
async function command(value, expected = value) {
  const count = events().length;
  const destination = path.join(directory, 'first', 'command');
  fs.writeFileSync(destination + '.pending', value);
  fs.renameSync(destination + '.pending', destination);
  await waitFor(() => events().slice(count).some(event => event.event === expected), value);
  return events().slice(count).find(event => event.event === expected);
}
async function stateWhen(predicate, label) {
  const deadline = Date.now() + 6000;
  let state;
  do {
    state = await command('state');
    if (predicate(state)) return state;
    await sleep(20);
  } while (Date.now() < deadline);
  assert.fail(`${label}: ${JSON.stringify(state)}`);
}
function find(text, identifier) {
  const line = text.split('\n').find(line => line.includes(identifier));
  assert.ok(line, `Missing ${identifier}: ${text}`);
  const match = line.match(/^\s*(\d+)\s/);
  assert.ok(match, `Missing native element ID: ${line}`);
  return match[1];
}
const action = value => request('PerformAction', { action: value }, 'node_repl');
const selected = (editor, text, context = {}) => action({ selectText: { elementID: editor, text, selection: 'text', ...context } });
const pass = value => console.log(`PASS ${value}`);
try {
  await waitFor(() => fs.existsSync(socket), 'service socket');
  const target = await openTarget('first');
  const initial = await request('GetAppSnapshot', { disableDiff: true });
  const firstImage = jpeg(initial, target);
  fs.writeFileSync(path.join(directory, 'native-first.txt'), initial.appSnapshot.text);
  let editor = find(initial.appSnapshot.text, 'input-editor');
  let button = find(initial.appSnapshot.text, 'input-button');
  pass('native request returns rendered element IDs and a readable JPEG');
  if (pressErrorProbe) {
  const outcomes = [];
  for (const actionKind of ['click', 'secondary']) {
  for (const status of ['cannotComplete', 'attributeUnsupported', 'failure', 'actionUnsupported']) {
  await command(`press-status:${status}`, 'press-status-set');
  const observedTree = await request('GetAppSnapshot', { disableDiff: true });
  for (const generation of [9001, 9002]) {
    const fault = find(observedTree.appSnapshot.text, `failing-press-${generation}`);
    const start = events().length;
    let error;
    try {
      await action(actionKind === 'click'
        ? { click: { at: { elementID: { _0: fault } }, clickCount: 1, mouseButton: 0 } }
        : { performSecondaryAction: { elementID: fault, action: 'AXPress' } });
    }
    catch (caught) { error = caught; }
    await waitFor(() => events().slice(start).some(event => event.event === 'failed-press-attempt' && event.generation === generation), 'AX press attempt');
    // Observe a bounded interval after the response so a queued fallback event
    // cannot disappear merely because the fixture is terminated immediately.
    await sleep(250);
    const observed = events().slice(start);
    outcomes.push({ actionKind, status, generation, errorCode: error?.code ?? null,
      attempts: observed.filter(event => event.event === 'failed-press-attempt' && event.generation === generation).length,
      effects: observed.filter(event => event.event === 'button-action' && event.generation === generation).length,
      mouseDowns: observed.filter(event => event.event === 'input' && event.type === 1).length });
  }
  }
  }
  fs.writeFileSync(path.join(directory, 'press-error-outcomes.json'), JSON.stringify(outcomes, null, 2));
  for (const outcome of outcomes) {
    const ignored = ['cannotComplete', 'attributeUnsupported'].includes(outcome.status);
    assert.equal(outcome.errorCode, ignored ? null : -10008, JSON.stringify(outcome));
    assert.equal(outcome.attempts, 1);
    assert.equal(outcome.effects, outcome.generation === 9002 ? 1 : 0);
    assert.equal(outcome.mouseDowns, 0);
    pass(`controlled ${outcome.actionKind} ${outcome.status}: ${ignored ? 'ignored response' : 'error propagated'}, ${outcome.generation === 9002 ? 'one partial side effect' : 'no side effect'}, no fallback mouse click`);
  }
  const afterFailures = await request('GetAppSnapshot', { disableDiff: true });
  jpeg(afterFailures, target);
  assert.match(afterFailures.appSnapshot.text, /input-editor/);
  assert.equal((await command('state')).decoy, 'DO NOT TOUCH');
  pass('controlled AX errors preserve a usable capture session and the decoy document');
  await request('Modify', { modification: { deactivate: {} } });
  assert.ok(!fs.existsSync(firstImage));
  pass('controlled AX error session deactivates and releases delivered image files');
  } else {
  const incremental = await request('GetAppSnapshot', {}, 'node_repl');
  assert.equal(incremental.appSnapshot.text, 'no_change');
  pass('unchanged native capture renders the no_change response');
  const beforeMenu = await command('state');
  const mainWindowIDs = new Set([...initial.appSnapshot.text.matchAll(/^\s*(\d+)\s/gm)].map(match => match[1]));
  await command('focus-decoy', 'decoy-focused');
  const decoyCapture = await request('GetAppSnapshot');
  fs.writeFileSync(path.join(directory, 'native-decoy.txt'), decoyCapture.appSnapshot.text);
  const decoyEditor = decoyCapture.appSnapshot.text.split('\n').find(line => line.includes('decoy-editor'));
  assert.ok(decoyEditor, decoyCapture.appSnapshot.text);
  const decoyID = decoyEditor.match(/^[+~]?\s*(\d+)\s/);
  assert.ok(decoyID && !mainWindowIDs.has(decoyID[1]), 'Window changes must not restart the published ID namespace');
  const decoyFull = await request('GetAppSnapshot');
  assert.equal(decoyFull.appSnapshot.text, 'no_change');
  pass('changing the focused native window retains an incremental revision');
  await command('reset');
  const mainAgain = await request('GetAppSnapshot');
  fs.writeFileSync(path.join(directory, 'native-main-return.txt'), mainAgain.appSnapshot.text);
  const mainFull = await request('GetAppSnapshot', { disableDiff: true });
  editor = find(mainFull.appSnapshot.text, 'input-editor');
  button = find(mainFull.appSnapshot.text, 'input-button');
  const menuBar = find(mainFull.appSnapshot.text, 'Owned Actions');
  const open = async () => {
    await action({ click: { at: { elementID: { _0: menuBar } }, clickCount: 1, mouseButton: 0 } });
    const opened = await request('GetAppSnapshot', { disableDiff: true });
    assert.equal(opened.appSnapshot.screenshot, undefined);
    assert.match(opened.appSnapshot.text, /Run owned action/);
    assert.ok(!opened.appSnapshot.text.includes('input-editor'));
    assert.ok(!opened.appSnapshot.text.includes('<app window='));
    return opened;
  };
  let opened = await open();
  fs.writeFileSync(path.join(directory, 'native-open-menu.txt'), opened.appSnapshot.text);
  pass('focused menu uses native rendering and omits the screenshot');
  const disabledItem = find(opened.appSnapshot.text, 'Disabled owned action');
  const disabledCount = events().length;
  try {
    await action({ click: { at: { elementID: { _0: disabledItem } }, clickCount: 1, mouseButton: 0 } });
  } catch (error) {
    assert.equal(error.code, -10008);
  }
  assert.ok(!events().slice(disabledCount).some(event => event.event === 'menu-action' && event.item === 3));
  pass('disabled menu item never invokes its target action');
  const ownedRun = find(opened.appSnapshot.text, 'Run owned action');
  let menuCount = events().length;
  await action({ click: { at: { elementID: { _0: ownedRun } }, clickCount: 1, mouseButton: 0 } });
  await waitFor(() => events().slice(menuCount).some(event => event.event === 'menu-action' && event.item === 1), 'native menu item action');
  pass('native menu item render ID invokes the real AppKit action');
  let returned = await request('GetAppSnapshot', { disableDiff: true });
  jpeg(returned, target);
  assert.match(returned.appSnapshot.text, /input-editor/);
  editor = find(returned.appSnapshot.text, 'input-editor');
  button = find(returned.appSnapshot.text, 'input-button');
  pass('menu completion returns to the native window tree with a JPEG');
  const secondMenuBar = find(returned.appSnapshot.text, 'Owned Actions');
  await action({ click: { at: { elementID: { _0: secondMenuBar } }, clickCount: 1, mouseButton: 0 } });
  opened = await request('GetAppSnapshot', { disableDiff: true });
  const nestedHeader = find(opened.appSnapshot.text, 'Nested actions');
  await action({ click: { at: { elementID: { _0: nestedHeader } }, clickCount: 1, mouseButton: 0 } });
  const nestedCapture = await request('GetAppSnapshot', { disableDiff: true });
  fs.writeFileSync(path.join(directory, 'native-nested-menu.txt'), nestedCapture.appSnapshot.text);
  const nestedRun = find(nestedCapture.appSnapshot.text, 'Run nested action');
  menuCount = events().length;
  await action({ click: { at: { elementID: { _0: nestedRun } }, clickCount: 1, mouseButton: 0 } });
  await waitFor(() => events().slice(menuCount).some(event => event.event === 'menu-action' && event.item === 2), 'native nested menu action');
  pass('native nested submenu ID invokes the intended nested action');
  returned = await request('GetAppSnapshot', { disableDiff: true });
  editor = find(returned.appSnapshot.text, 'input-editor');
  button = find(returned.appSnapshot.text, 'input-button');
  const afterMenu = await command('state');
  assert.equal(afterMenu.text, beforeMenu.text);
  assert.equal(afterMenu.decoy, beforeMenu.decoy);
  pass('menu navigation preserves both document contents');
  await selected(editor, 'café');
  let actual = await command('state');
  assert.deepEqual(actual.selection, [actual.text.indexOf('cafe\u0301'), 5]);
  assert.equal(actual.decoy, 'DO NOT TOUCH');
  pass('published native editor ID selects the decomposed source text');
  const source = actual.text;
  const offset = source.indexOf('segundo alvo') + 'segundo '.length;
  await selected(editor, 'alvo', { prefix: 'segundo ', suffix: ' fim' });
  assert.deepEqual((await command('state')).selection, [offset, 4]);
  await selected(editor, 'alvo', { prefix: 'segundo ', selection: 'cursor_before' });
  assert.deepEqual((await command('state')).selection, [offset, 0]);
  await selected(editor, 'alvo', { prefix: 'segundo ', selection: 'cursor_after' });
  assert.deepEqual((await command('state')).selection, [offset + 4, 0]);
  pass('native context selection and both cursor modes preserve UTF-16 offsets');
  const before = await command('state');
  for (const text of ['alvo', 'missing selection']) {
    await assert.rejects(selected(editor, text), error => error.code === -10008);
    const after = await command('state');
    assert.equal(after.text, before.text);
    assert.deepEqual(after.selection, before.selection);
  }
  pass('ambiguous and missing native text leave content and selection unchanged');
  await action({ setValue: { elementID: editor, value: 'e\u0301text étext' } });
  const changed = await request('GetAppSnapshot', { disableDiff: true });
  editor = find(changed.appSnapshot.text, 'input-editor');
  button = find(changed.appSnapshot.text, 'input-button');
  await selected(editor, 'text', { prefix: 'é' });
  assert.deepEqual((await command('state')).selection, [8, 4]);
  pass('native capture refreshes the changed value and selection resolves fixed-length Unicode context');
  await action({ setValue: { elementID: editor, value: source } });
  const restored = await request('GetAppSnapshot', { disableDiff: true });
  editor = find(restored.appSnapshot.text, 'input-editor');
  button = find(restored.appSnapshot.text, 'input-button');
  await selected(editor, '👩🏽‍💻', { selection: 'cursor_after' });
  await action({ type: { _0: ' / native 🙂' } });
  actual = await stateWhen(state => state.text === source + ' / native 🙂', 'fixture consumes complete Unicode input');
  assert.equal(actual.text, source + ' / native 🙂');
  assert.equal(actual.decoy, 'DO NOT TOUCH');
  pass('native rendered ID selection composes with Unicode keyboard input');
  const click = id => action({ click: { at: { elementID: { _0: id } }, clickCount: 1, mouseButton: 0 } });
  let count = events().length;
  await click(button);
  await waitFor(() => events().slice(count).some(event => event.event === 'button-action' && event.attached), 'first button action');
  pass('native rendered button ID delivers a real button action');
  const replacement = await command('replace-button', 'button-replaced');
  count = events().length;
  await click(button);
  await waitFor(() => events().slice(count).some(event => event.event === 'button-action' && event.attached && event.generation === replacement.generation), 'replacement button action');
  pass('native refetch recovers the unique attached replacement control');
  const refreshed = await request('GetAppSnapshot');
  fs.writeFileSync(path.join(directory, 'native-after-replacement.txt'), refreshed.appSnapshot.text);
  const full = await request('GetAppSnapshot', { disableDiff: true });
  button = find(full.appSnapshot.text, 'input-button');
  await command('insert-button', 'button-inserted');
  const added = await request('GetAppSnapshot');
  assert.match(added.appSnapshot.text, /extra-button/);
  const withExtra = await request('GetAppSnapshot', { disableDiff: true });
  const stableButton = find(withExtra.appSnapshot.text, 'input-button');
  // disableDiff intentionally starts a root revision, so compare consecutive
  // incremental captures rather than borrowing IDs from a discarded lineage.
  count = events().length;
  await click(stableButton);
  await waitFor(() => events().slice(count).some(event => event.event === 'button-action'), 'button after insertion');
  pass('native insertion diff and complete recapture retain actionable controls');
  await command('ambiguous-button', 'button-ambiguous');
  count = events().length;
  await assert.rejects(click(stableButton), error => error.code === -10008);
  assert.equal(events().slice(count).filter(event => event.event === 'button-action').length, 0);
  pass('native recovery rejects duplicate replacements before a button action');
  assert.ok(fs.existsSync(firstImage));
  await request('Modify', { modification: { deactivate: {} } });
  assert.ok(!fs.existsSync(firstImage));
  pass('native pipeline preserves delivered-image lifetime and deactivation cleanup');
  }
} finally {
  for (const child of [service, ...fixtures]) child.kill('SIGTERM');
  console.log(`Owned fixture directory: ${directory}`);
}
