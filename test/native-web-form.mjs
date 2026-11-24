import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { requireNativeDesktop, startNativeDesktop } from './native-desktop-service.mjs';
import { uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
requireNativeDesktop();
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-web-form-'));
const bundle = uniqueFixtureBundle('test.acua.owned-web-form');
const app = path.join(directory, 'OwnedWebForm.app');
const executable = path.join(app, 'Contents/MacOS/OwnedWebForm');
fs.mkdirSync(path.dirname(executable), { recursive: true });
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>OwnedWebForm</string><key>CFBundleName</key><string>OwnedWebForm</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/WebFormFixture.swift'), '-o', executable], { stdio: 'inherit' });
execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
const ownerProbe = path.join(directory, 'ax-owners');
execFileSync('swiftc', ['-O', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/WebFormAXOwners.swift'), '-o', ownerProbe], { stdio: 'inherit' });
// Requests name the fixture by path; see fixtureAppTarget.
const fixtureApp = fixtureAppTarget(app);
const { socket, service } = startNativeDesktop(directory, bundle, fixtureApp);
const fixture = spawn(executable, [directory], { stdio: ['ignore', 'ignore', 'inherit'] });
const events = () => {
  const file = path.join(directory, 'events.jsonl');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
};
async function until(predicate, label) {
  for (let i = 0; i < 240; ++i) { const value = predicate(); if (value) return value; await sleep(50); }
  assert.fail(label);
}
async function command(value, expected = value) {
  const count = events().length;
  const destination = path.join(directory, 'command');
  fs.writeFileSync(destination + '.pending', value); fs.renameSync(destination + '.pending', destination);
  return until(() => events().slice(count).find(event => event.event === expected), value);
}
async function request(name, fields = {}, clientType) {
  const body = Buffer.from(JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'ownedFixtureNativeRequest', params: {
    requestType: `ComputerUseIPCApp${name}Request`, request: { app: fixtureApp, ...fields }, clientType,
  } }));
  const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  const client = net.createConnection({ path: socket });
  try {
    const response = await new Promise((resolve, reject) => {
      let buffer = Buffer.alloc(0);
      client.on('connect', () => client.write(Buffer.concat([header, body])));
      client.on('data', chunk => {
        buffer = Buffer.concat([buffer, chunk]);
        if (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) resolve(JSON.parse(buffer.subarray(4, buffer.readUInt32LE(0) + 4).toString()));
      });
      client.on('error', reject); client.on('close', () => reject(new Error('Socket closed without a response')));
      client.setTimeout(20000, () => reject(new Error('Native request timed out')));
    });
    if (response.error) { const error = new Error(JSON.stringify(response.error)); error.code = response.error.code; throw error; }
    return response.result;
  } finally { client.destroy(); }
}
const action = value => request('PerformAction', { action: value }, 'node_repl');
const click = id => action({ click: { at: { elementID: { _0: id } }, clickCount: 1, mouseButton: 0 } });
const find = (text, label, role) => {
  const line = text.split('\n').find(line => line.includes(label) && (!role || line.includes(role)));
  assert.ok(line, `Missing ${label}: ${text}`);
  const match = line.match(/^\s*(\d+)\s/); assert.ok(match, line); return match[1];
};
const capture = async label => {
  const result = await request('GetAppSnapshot', { disableDiff: true });
  fs.writeFileSync(path.join(directory, `${label}.json`), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(directory, `${label}.txt`), result.appSnapshot.text);
  return result;
};
const pass = label => console.log(`PASS ${label}`);
try {
  await until(() => fs.existsSync(socket), 'service socket');
  await until(() => events().some(event => event.event === 'ready'), 'WebKit navigation finished');
  // didFinish only proves DOM navigation completed. Independently observe the
  // owned accessibility server before taking the first service snapshot; do
  // not retry GetAppSnapshot to turn an empty first result into a passing capture.
  let owners;
  await until(() => {
    owners = JSON.parse(execFileSync(ownerProbe, [String(fixture.pid)], { encoding: 'utf8', timeout: 5000 }));
    return ['AXWebArea', 'AXTextField', 'AXSlider'].every(role => owners.some(e =>
      e.role === role && e.pid === fixture.pid && e.actualPID > 0 && e.actualPID !== fixture.pid && e.actualPIDStatus === 0));
  }, 'owned WebKit AX controls published');
  fs.writeFileSync(path.join(directory, 'ax-owners.json'), JSON.stringify(owners, null, 2));
  for (const role of ['AXWebArea', 'AXTextField', 'AXSlider']) {
    assert.ok(owners.some(e => e.role === role && e.pid === fixture.pid && e.actualPID > 0 && e.actualPID !== fixture.pid && e.actualPIDStatus === 0), `No remote WebKit owner for ${role}`);
  }
  pass('AX probe confirms browser controls belong to a distinct WebKit process behind the app PID');
  let shot = await capture('initial');
  assert.equal(shot.app.pid, fixture.pid);
  assert.equal(shot.appSnapshot.screenshot.mimeType, 'image/jpeg');
  const image = fileURLToPath(shot.appSnapshot.screenshot.url);
  assert.equal(fs.readFileSync(image).subarray(0, 2).toString('hex'), 'ffd8');
  let name = find(shot.appSnapshot.text, 'Owned name field', 'text field');
  let notes = find(shot.appSnapshot.text, 'Owned notes field', 'text entry area');
  let submit = find(shot.appSnapshot.text, 'Submit owned form');
  pass('native renderer publishes actionable WebKit form IDs and a real JPEG');
  {
    // The first element click on remote WebKit content resolves its mouse
    // target from the AX field (ControllerMouseEventTargeting). Record what
    // that path reads, so a failure explains itself: the field's AX frame,
    // owning PIDs and AXUIElementGetWindow status, a system-wide hit test at
    // its centre, the CG window bounds and the screen layout.
    const probed = JSON.parse(execFileSync(ownerProbe, [String(fixture.pid)], { encoding: 'utf8', timeout: 5000 }));
    const field = probed.find(e => e.role === 'AXTextField' && e.title === 'Owned name field');
    const diagnostics = { renderedLine: shot.appSnapshot.text.split('\n').find(line => line.includes('Owned name field') && line.includes('text field')),
      field, screens: probed.find(e => e.role === 'OwnedScreenProbe')?.screens, windowBounds: (await command('state')).windowBounds };
    fs.writeFileSync(path.join(directory, 'name-click-diagnostics.json'), JSON.stringify(diagnostics, null, 2));
    console.log(`DIAGNOSTIC first WebKit field click: ${JSON.stringify(diagnostics)}`);
    try { await click(name); }
    catch (error) { error.message += ` while clicking the WebKit name field; diagnostics: ${JSON.stringify(diagnostics)}`; throw error; }
    await action({ pressKey: { _0: 'Command+a' } });
    let typed = 'Agente 🙂 café 日本語';
    await action({ type: { _0: typed } });
    await until(() => events().find(e => e.event === 'dom' && e.kind === 'input' && e.target === 'name' && e.value === typed), 'browser consumes complete Unicode input');
    let state = await command('state');
    assert.equal(state.name, typed); assert.equal(state.decoy, 'DO NOT TOUCH WEB DECOY');
    assert.ok(events().some(e => e.event === 'dom' && e.kind === 'input' && e.target === 'name' && e.trusted));
    pass('WebKit input receives trusted Unicode typing through the native keyboard path');
    shot = await capture('typed');
    name = find(shot.appSnapshot.text, 'Owned name field', 'text field');
    await action({ selectText: { elementID: name, text: 'café', prefix: 'Agente 🙂 ', suffix: ' 日本語', selection: 'text' } });
    state = await command('state');
    const start = typed.indexOf('café');
    assert.deepEqual(state.nameSelection, [start, start + 4]);
    pass('remote WebKit text field selection resolves contextual UTF-16 source offsets');
    const replaced = typed.slice(0, start) + 'cafe\u0301 👩🏽‍💻' + typed.slice(start + 4);
    await action({ type: { _0: 'cafe\u0301 👩🏽‍💻' } });
    await until(() => events().find(e => e.event === 'dom' && e.kind === 'input' && e.target === 'name' && e.value === replaced), 'browser consumes selection replacement');
    state = await command('state'); assert.equal(state.name, replaced); typed = replaced;
    pass('native typing replaces only the selected browser field substring');
    shot = await capture('replaced');
    notes = find(shot.appSnapshot.text, 'Owned notes field', 'text entry area'); submit = find(shot.appSnapshot.text, 'Submit owned form');
    await click(notes);
    const source = state.notes;
    // Selection resolves text from the selected rendered node,
    // rather than searching its descendants. WebKit publishes the textarea
    // wrapper and its selectable text as separate nodes. Selection failures
    // are ControllerTextSelectionFailure, classified as -10005 by case name.
    await assert.rejects(action({ selectText: { elementID: notes, text: 'alvo', prefix: 'segundo ', suffix: ' fim', selection: 'text' } }),
      error => error.code === -10005 && error.message.includes('sourceRangeUnavailable'));
    assert.equal((await command('state')).notes, source);
    pass('browser wrapper selection rejects text outside its own captured source without modifying the document');
    notes = find(shot.appSnapshot.text, 'primeiro alvo', 'text (settable)');
    // The static text child does not publish a settable AXSelectedTextRange;
    // selection checks that before resolving any source range.
    await assert.rejects(action({ selectText: { elementID: notes, text: 'alvo', prefix: 'segundo ', suffix: ' fim', selection: 'text' } }),
      error => error.code === -10005 && error.message.includes('selectionNotSettable'));
    assert.equal((await command('state')).notes, source);
    const textOwner = owners.find(e => e.role === 'AXTextArea' && e.title === 'Owned notes field');
    assert.equal(textOwner.attributedString, '\ufffc');
    assert.ok(owners.some(e => e.role === 'AXStaticText' && e.value === source && !e.selectionSettable));
    pass('WebKit text attachment and nonselectable child limitations are observed without inventing a descendant selection fallback');
    await action({ pressKey: { _0: 'Command+a' } });
    const expectedNotes = 'Área de texto editada 🙂 cafe\u0301 👩🏽‍💻';
    await action({ type: { _0: expectedNotes } });
    await until(() => events().find(e => e.event === 'dom' && e.kind === 'input' && e.target === 'notes' && e.value === expectedNotes), 'browser consumes complete replacement input');
    state = await command('state');
    assert.equal(state.notes, expectedNotes);
    assert.equal(state.name, typed); assert.equal(state.decoy, 'DO NOT TOUCH WEB DECOY');
    pass('standard keyboard selection and Unicode editing work in the remote WebKit textarea');
    shot = await capture('selected');
    name = find(shot.appSnapshot.text, 'Owned name field', 'text field');
    await command('focus-decoy', 'decoy-focused');
    // No action moves an app's keyboard focus to another of its windows: an
    // element click does not make a background window key. The app (here the
    // fixture) returns focus to the form's window, then the field is clicked.
    await command('focus-main', 'main-focused');
    shot = await capture('refocused');
    name = find(shot.appSnapshot.text, 'Owned name field', 'text field');
    await click(name);
    await action({ pressKey: { _0: 'Command+a' } });
    typed = 'Campo correto após mudar de janela 🙂';
    await action({ type: { _0: typed } });
    await until(() => events().find(e => e.event === 'dom' && e.kind === 'input' && e.target === 'name' && e.value === typed), 'browser field after decoy focus');
    state = await command('state');
    assert.equal(state.name, typed); assert.equal(state.notes, expectedNotes); assert.equal(state.decoy, 'DO NOT TOUCH WEB DECOY');
    assert.equal(state.keyWindow, events().find(e => e.event === 'ready').window);
    pass('published browser ID restores the intended window after a native decoy takes focus');
    shot = await capture('focused');
    submit = find(shot.appSnapshot.text, 'Submit owned form');
    let count = events().length;
    await click(submit);
    await until(() => events().slice(count).find(e => e.event === 'dom' && e.kind === 'submit' && e.trusted), 'trusted form submit');
    state = await command('state'); assert.equal(state.submissions, 1);
    pass('published browser button ID submits the actual owned HTML form once');
    shot = await capture('submitted');
    const disabled = find(shot.appSnapshot.text, 'Disabled owned button');
    count = events().length;
    // Neither the AX press nor the mouse path reports a disabled DOM control;
    // the only legitimate error is a failed AX action status (-10008).
    try { await click(disabled); } catch (error) { assert.equal(error.code, -10008, error.message); }
    assert.ok(!events().slice(count).some(e => e.event === 'dom' && e.kind === 'click' && e.target === 'disabled'));
    assert.equal((await command('state')).submissions, 1);
    pass('disabled browser button never dispatches a click or submits the form');
    state = await command('state');
    const frame = state.windowBounds;
    const dim = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', fileURLToPath(shot.appSnapshot.screenshot.url)], { encoding: 'utf8' });
    const width = Number(dim.match(/pixelWidth:\s*(\d+)/)[1]), height = Number(dim.match(/pixelHeight:\s*(\d+)/)[1]);
    const [x,y,w,h] = state.sliderScreen;
    // Native range thumbs are 16 CSS pixels wide: map the thumb center rather
    // than the full input edge onto the known min/max interval.
    const pixel = (px,py) => [Math.round((px-frame.X)*width/frame.Width), Math.round((py-frame.Y)*height/frame.Height)];
    const from = pixel(x+8+(w-16)*0.2,y+h/2), to = pixel(x+8+(w-16)*0.8,y+h/2);
    count = events().length;
    await action({ drag: { from, to } });
    // WebKit dispatches the range input in the WebContent process after the
    // drag reply returns, so wait for the trusted input that settles near 80
    // before reading the state. Without the wait a fast reply reads level 20.
    await until(() => events().slice(count).find(e => e.event === 'dom' && e.kind === 'input' && e.target === 'level' && e.trusted && Math.abs(Number(e.value)-80)<=3),
      'trusted slider input near 80 after the drag');
    state = await command('state');
    assert.ok(Math.abs(state.level-80)<=3, `slider ended at ${state.level}`);
    // A drag posts only start, midpoint and destination drag events
    // (ControllerNativeCoordinateEvents) and they may be coalesced, so only a
    // trusted input event during the drag is guaranteed, not a midway value.
    assert.ok(events().slice(count).some(e => e.event === 'dom' && e.kind === 'input' && e.target === 'level' && e.trusted),
      'the range input reports trusted input during the drag');
    pass('screenshot-pixel drag changes the real WebKit slider through intermediate values');
    assert.equal(state.decoy, 'DO NOT TOUCH WEB DECOY'); assert.equal(state.name, typed); assert.equal(state.submissions, 1);
    pass('browser actions preserve the decoy document and unrelated form values');
    fs.writeFileSync(path.join(directory, 'verified-final-state.json'), JSON.stringify(state, null, 2));
    await request('Modify', { modification: { deactivate: {} } });
    assert.ok(!fs.existsSync(image));
    pass('browser observation files are removed when the automation session deactivates');
  }
} finally {
  await Promise.all([service, fixture].map(child => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    return new Promise(resolve => {
      const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.kill('SIGTERM');
    });
  }));
  console.log(`Owned web form directory: ${directory}`);
}
