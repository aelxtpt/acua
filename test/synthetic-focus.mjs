import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import net from 'node:net';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-synthetic-focus-'));
const probe = '/tmp/cua-synthetic-focus-probe';
const executable = path.join(temp, 'InputFixture');
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/InputFixture.swift'), '-o', executable], { stdio: 'inherit' });
const processes = [];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(body, label, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const value = await body(); if (value) return value; await pause(20); }
  throw new Error(`Timeout ${label}; artifacts ${temp}`);
}
function events(directory) {
  try { return fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch { return []; }
}
async function fixture(name) {
  const directory = path.join(temp, name), app = path.join(directory, 'FocusFixture.app'), macos = path.join(app, 'Contents/MacOS');
  fs.mkdirSync(macos, { recursive: true });
  fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle(name)}</string><key>CFBundleExecutable</key><string>FocusFixture</string><key>CFBundleName</key><string>Focus ${name}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  const binary = path.join(macos, 'FocusFixture'); fs.copyFileSync(executable, binary);
  execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
  const process = spawn(binary, [directory], { stdio: ['ignore', 'ignore', 'inherit'] }); processes.push(process);
  const ready = await until(() => events(directory).find(e => e.event === 'ready'), `${name} ready`);
  return { directory, process, ready };
}
async function state(app) {
  const before = events(app.directory).length;
  publishFixtureCommand(path.join(app.directory, 'command'), 'state');
  return until(() => events(app.directory).slice(before).find(e => e.event === 'state'), 'state');
}
async function stateWhen(app, predicate, label) {
  let observed;
  await until(async () => { observed = await state(app); return predicate(observed); }, label);
  return observed;
}
function invoke(mode, fixture, ...args) {
  return JSON.parse(execFileSync(probe, [mode, String(fixture.process.pid), ...args.map(String)], { encoding: 'utf8' }));
}
let service, client, control;
const socket = path.join(temp, 'service.sock');
let passed = 0;
const check = (name, ok) => { assert.ok(ok, name); passed++; console.log(`PASS ${name}`); };
const bundle = name => uniqueFixtureBundle(`test.acua.focus-fixture.${name}`);
const appTarget = name => fixtureAppTarget(path.join(temp, name, 'FocusFixture.app'));
try {
  service = spawn(serviceTestExecutable(root), [socket], {
    env: serviceTestEnvironment({ ...process.env, ACUA_DIAGNOSTICS: '1' }), stdio: ['ignore', 'ignore', 'inherit'] });
  await until(() => fs.existsSync(socket), 'service ready');
  globalThis.nodeRepl = { env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket }, requestMeta: {},
    nativePipe: { createConnection: socketPath => new Promise((resolve, reject) => {
      const stream = net.createConnection({ path: socketPath }); stream.once('connect', () => resolve(stream)); stream.once('error', reject);
    }) } };
  const { MacComputerUseClient } = await import('./support/js-client/client.js');
  client = new MacComputerUseClient(); control = new MacComputerUseClient();
  const target = await fixture('target');
  await client.getAppState(appTarget('target'));
  const decoy = await fixture('decoy');
  await until(() => invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid, 'decoy frontmost');
  const initial = await state(target), initialDecoy = await state(decoy);
  check('target is genuinely in the background before automation', !initial.isActive && initial.frontmostPID === decoy.process.pid);
  const keyboardBefore = invoke('inspect', decoy);
  check('private keyboard-focus query resolves the foreground fixture', keyboardBefore.keyboardFocusAvailable && keyboardBefore.keyboardQueryStatus === 0 && keyboardBefore.keyboardProcessStatus === 0 && keyboardBefore.keyboardFocusPID === decoy.process.pid);
  await client.pressKey({ app: appTarget('target'), key: 'Super_L+a' });
  let actual = await stateWhen(target, value => value.selection[0] === 0 && value.selection[1] === value.text.length, 'background selection');
  check('background Cmd-A performs the real menu action', actual.selection[0] === 0 && actual.selection[1] === actual.text.length);
  check('receiver believes it is active and has the requested key window', actual.isActive && actual.keyWindow === target.ready.window);
  check('the real foreground application remains the decoy', actual.frontmostPID === decoy.process.pid);
  check('receiver activation preserves the real keyboard-focus owner', invoke('inspect', target).keyboardFocusPID === decoy.process.pid);
  const panelStart = events(target.directory).length;
  publishFixtureCommand(path.join(target.directory, 'command'), 'nonactivating-panel');
  await until(() => events(target.directory).slice(panelStart).some(e => e.event === 'nonactivating-panel'), 'nonactivating panel created');
  await until(() => invoke('inspect', target).keyboardFocusPID === target.process.pid, 'panel holds real keyboard focus');
  check('nonactivating panel separates real keyboard focus from actual foreground', invoke('inspect', target).actualFrontmostPID === decoy.process.pid);
  await client.modifyApp(appTarget('target'), 'deactivate');
  await until(async () => !(await state(target)).isActive, 'deactivation with panel-held real keyboard focus');
  const teardownObservation = invoke('inspect', target);
  console.log('TEARDOWN FOCUS DIAGNOSTICS', JSON.stringify({ expectedForegroundPID: decoy.process.pid, targetPID: target.process.pid, observed: teardownObservation }));
  check('teardown deactivates a background receiver even when it owns real keyboard focus', teardownObservation.actualFrontmostPID === decoy.process.pid);
  publishFixtureCommand(path.join(target.directory, 'command'), 'close-panel');
  await until(() => events(target.directory).slice(panelStart).some(e => e.event === 'panel-closed'), 'panel closed');
  await until(() => invoke('inspect', decoy).keyboardFocusPID === decoy.process.pid, 'panel returns keyboard focus');
  await client.getAppState(appTarget('target'));
  await client.typeText({ app: appTarget('target'), text: 'synthetic 🙂 café' });
  actual = await stateWhen(target, value => value.text === 'synthetic 🙂 café', 'background Unicode delivered');
  check('background Unicode typing reaches the target', actual.text === 'synthetic 🙂 café');
  await client.paste({ app: appTarget('target'), text: ' / colado', format: 'text' });
  actual = await stateWhen(target, value => value.text === 'synthetic 🙂 café / colado', 'background paste delivered');
  check('background paste uses the target responder chain', actual.text === 'synthetic 🙂 café / colado');
  check('typing and paste preserve the actual foreground process', actual.frontmostPID === decoy.process.pid);
  check('the foreground editor is unchanged', (await state(decoy)).text === initialDecoy.text);
  const deactivated = await client.modifyApp(appTarget('target'), 'deactivate');
  check('explicit deactivation ends the automation session', deactivated.active === false);
  await until(() => invoke('inspect', target).axFrontmost === false, 'synthetic deactivation');
  actual = await state(target);
  check('deactivation restores receiver state without activating the decoy again', !actual.isActive && actual.frontmostPID === decoy.process.pid);
  await client.getAppState(appTarget('target'));
  await client.pressKey({ app: appTarget('target'), key: 'Super_L+a' });
  check('a new observation can establish a fresh synthetic focus session', (await state(target)).selection[1] === actual.text.length);
  // The native parser rejects a chord without a physical
  // key, so each held modifier rides on F13, which types nothing.
  const interventionStart = events(target.directory).length;
  const interrupted = client.pressKey({ app: appTarget('target'), key: 'Shift_L+F13', duration: 1 }).then(value => ({ value }), error => ({ error }));
  await until(() => events(target.directory).slice(interventionStart).some(e => e.type === 12 && (e.flags & 0x20000)), 'modifier before intervention');
  const interventionAt = Date.now();
  publishFixtureCommand(path.join(target.directory, 'command'), 'external-intervention');
  // Intervention admission (ControllerInterventionAdmission) lets input that
  // is already held finish; an intervention gates the next request instead, which
  // waits out the debounce and then requires a fresh get_app_state.
  const interruptedOutcome = await interrupted;
  assert.equal(interruptedOutcome.error, undefined, `held input completes across an intervention: ${JSON.stringify(interruptedOutcome.error?.message)}`);
  check('held input already in progress completes across an external intervention', true);
  await assert.rejects(client.pressKey({ app: appTarget('target'), key: 'F13' }),
    error => error.code === -10016 && error.message.includes('Re-query the latest state'));
  check('after an intervention the next action requires a state requery', true);
  // The deadline is registered after the fixture posts the event, so the
  // refusal cannot arrive before the 5 s debounce has elapsed.
  check('the refused action first waits out the intervention debounce', Date.now() - interventionAt >= 4900);
  check('an intervention preserves the actual foreground process', invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid);
  // The refusal came only after the debounce ended, so this requery is already
  // quiet and clears the intervention (clearUserInterruptedInterventionAfterStateRequery).
  await client.getAppState(appTarget('target'));
  await client.pressKey({ app: appTarget('target'), key: 'Super_L+a' });
  check('quiet state requery establishes focus after interruption', (await state(target)).isActive);
  const before = events(target.directory).length;
  const held = client.pressKey({ app: appTarget('target'), key: 'Shift_L+F13', duration: 1 }).then(value => ({ value }), error => ({ error }));
  await until(() => events(target.directory).slice(before).some(e => e.type === 12 && (e.flags & 0x20000)), 'held modifier');
  const heldAt = Date.now();
  // During the quiet requery interval a different application may become
  // foreground. Stop must preserve the current owner, including that change.
  const beforeStop = invoke('inspect', target);
  assert.ok(beforeStop.actualFrontmostPID > 0 && beforeStop.actualFrontmostPID !== target.process.pid,
    'Stop scenario requires a genuinely background target');
  assert.ok(beforeStop.keyboardFocusAvailable && beforeStop.keyboardFocusPID > 0,
    'Stop scenario requires a valid native keyboard-focus baseline');
  console.log('STOP FOCUS BASELINE', JSON.stringify(beforeStop));
  // Stop marks the target at once but deactivates on the instance's serial
  // queue after the jobs already queued. The hold sleeps
  // without observing that mark, so the chord runs its full duration, releases
  // normally and the request succeeds; only later requests see -10012.
  const stopped = await control.stopApp(appTarget('target'));
  const stopWaited = Date.now() - heldAt;
  const heldOutcome = await held;
  assert.equal(heldOutcome.error, undefined, `held input completes before Stop: ${JSON.stringify(heldOutcome.error?.message)}`);
  check('Stop lets held background input queued before it complete', stopped.active === false && stopped.currentApp?.pid === target.process.pid);
  check('Stop tears down only after the full hold duration', stopWaited >= 750);
  await until(() => events(target.directory).slice(before).some(e => e.type === 12 && !(e.flags & 0x20000)), 'modifier released');
  check('the held modifier is released by the completed request', true);
  await until(() => invoke('inspect', target).axFrontmost === false, 'Stop tears down synthetic focus');
  actual = await state(target);
  check('Stop leaves the app alive and removes invented activation', target.process.exitCode === null && !actual.isActive);
  check('Stop preserves the real foreground application', actual.frontmostPID === beforeStop.actualFrontmostPID);
  check('Stop preserves real keyboard focus after receiver teardown', invoke('inspect', target).keyboardFocusPID === beforeStop.keyboardFocusPID);
  await assert.rejects(client.pressKey({ app: appTarget('target'), key: 'a' }), error => error.code === -10012);
  check('stopped sessions cannot synthesize focus through another action', !(await state(target)).isActive);
  // The stop reason outlives the removed instance and is checked before a new
  // controller is built, so a state query cannot reopen the session.
  await assert.rejects(client.getAppState(appTarget('target')), error => error.code === -10012);
  check('stopped sessions cannot be reopened by a state query', !(await state(target)).isActive);
  for (const [name, key, mask] of [['stop-control-shift', 'Control_L+Shift_L+F13', 0x60000], ['stop-command-option', 'Super_L+Alt_L+F13', 0x180000]]) {
    const receiver = await fixture(name);
    await until(async () => (await client.listApps()).some(app => app.bundleIdentifier === bundle(name)), `${name} discovered`);
    await client.getAppState(appTarget(name));
    execFileSync(probe, ['activate', String(decoy.process.pid)]);
    await until(() => invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid, `${name} foreground baseline`);
    const firstEvent = events(receiver.directory).length;
    const pending = client.pressKey({ app: appTarget(name), key, duration: 1 }).then(value => ({ value }), error => ({ error }));
    await until(() => events(receiver.directory).slice(firstEvent).some(e => e.type === 12 && (e.flags & mask) === mask), `${name} modifiers held`);
    const chordAt = Date.now();
    // As above, Stop queues its teardown behind the held chord rather than
    // cancelling it, so the chord completes and Stop resolves after it.
    const result = await control.stopApp(appTarget(name));
    const chordWaited = Date.now() - chordAt;
    const outcome = await pending;
    assert.equal(outcome.error, undefined, `${name}: held chord completes before Stop: ${JSON.stringify(outcome.error?.message)}`);
    check(`${name}: Stop lets the held chord complete`, result.active === false && result.currentApp?.pid === receiver.process.pid);
    check(`${name}: Stop waits for the full hold duration`, chordWaited >= 750);
    await until(() => events(receiver.directory).slice(firstEvent).some(e => e.type === 12 && (e.flags & mask) === 0), `${name} all modifiers released`);
    check(`${name}: final release reaches native responder`, true);
    await until(async () => !(await state(receiver)).isActive, `${name} deactivated`);
    check(`${name}: focus teardown follows the completed chord`, !(await state(receiver)).isActive);
    check(`${name}: original foreground is preserved`, invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid);
  }
  const shutdownTarget = await fixture('shutdown-target');
  await until(async () => (await client.listApps()).some(app => app.bundleIdentifier === bundle('shutdown-target')), 'service discovers newly launched shutdown target');
  await client.getAppState(appTarget('shutdown-target'));
  execFileSync(probe, ['activate', String(decoy.process.pid)]);
  await until(() => invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid, 'decoy before shutdown');
  await client.pressKey({ app: appTarget('shutdown-target'), key: 'Super_L+a' });
  check('shutdown fixture has synthetic focus while a different app is foreground', (await state(shutdownTarget)).isActive && invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid);
  // Native focus resources never deactivate on
  // destruction (ControllerSyntheticFocus deinit), so this restoration is owned
  // by the service's SIGTERM handler, which must reach the native instances.
  const exited = new Promise(resolve => service.once('exit', resolve));
  service.kill('SIGTERM');
  await exited;
  await until(() => invoke('inspect', shutdownTarget).axFrontmost === false, 'service shutdown tears down receiver activation');
  check('service shutdown restores a living target receiver', shutdownTarget.process.exitCode === null && !(await state(shutdownTarget)).isActive);
  console.log(`ALL ${passed} NATIVE SYNTHETIC FOCUS CHECKS PASSED — artifacts: ${temp}`);
} finally {
  for (const connection of [client, control]) if (connection) for (const transport of connection.transports.values()) { try { (await transport).close(); } catch {} }
  service?.kill('SIGTERM');
  for (const process of processes) process.kill('SIGTERM');
}
