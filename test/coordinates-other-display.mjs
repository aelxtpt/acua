// Screenshot-pixel input on a display other than the primary one, through the
// real service. The second display has its own origin in global coordinates
// (often negative) and may have another backing scale, so pixels must map
// through the capture of the window where it now is, not through the primary
// display's geometry.
//   - the target window moves to the other display and is captured there;
//   - click, drag/drop, scroll and the continuous slider land on targets
//     located only from that capture's pixels;
//   - after the window returns to the primary display and is re-read, a click
//     there lands again.
// It needs at least two displays and runs on request, apart from the physical
// groups: it types nothing, but clicks, drags and scrolls for real.
import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ['--diagnostics'], { encoding: 'utf8' }));
assert.ok(!diagnostics.screenLocked, 'needs an unlocked macOS session');
assert.ok(diagnostics.accessibility && diagnostics.screenRecording, 'needs Accessibility and Screen Recording permissions');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-other-display-'));
const app = path.join(temp, 'CUAOtherDisplayFixture.app');
const bundle = uniqueFixtureBundle('test.acua.other-display-fixture');
const fixture = path.join(app, 'Contents/MacOS/CUAOtherDisplayFixture');
fs.mkdirSync(path.dirname(fixture), { recursive: true });
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>CUAOtherDisplayFixture</string><key>CFBundleName</key><string>CUAOtherDisplayFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/CoordinateFixture.swift'), '-o', fixture], { stdio: 'inherit' });

const displays = JSON.parse(execFileSync(fixture, ['--display-info'], { encoding: 'utf8' }));
const displayList = Array.isArray(displays) ? displays : displays.displays;
assert.ok(displayList.length >= 2, `needs a second display; found ${displayList.length}`);

const fixtureProcess = spawn(fixture, [temp], { stdio: ['ignore', 'ignore', 'pipe'] });
fixtureProcess.stderr.on('data', data => process.stderr.write(data));
const fixtureApp = fixtureAppTarget(app);
const events = () => {
  try { return fs.readFileSync(path.join(temp, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); }
  catch { return []; }
};
async function until(predicate, label, milliseconds = 10000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    const result = await predicate();
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  throw new Error(`Timeout: ${label}`);
}
async function command(value, expected) {
  const before = events().length;
  publishFixtureCommand(path.join(temp, 'command'), value);
  return until(() => events().slice(before).find(event => event.event === expected), expected);
}
const after = (before, predicate, label) => until(() => events().slice(before).find(predicate), label);
// A capture reads the WindowServer frame, which follows a move across
// displays later than AppKit's own report, so wait for it before capturing.
async function windowServerFrameOn([x, y, width, height], label) {
  await until(async () => {
    const [left, top] = (await command('window-server-frame', 'window-server-frame')).frame;
    return left >= x && top >= y && left < x + width && top < y + height;
  }, label);
}
const primaryDisplay = displayList[0].bounds;
// Copies a capture next to the artifacts and finds the fixture's markers in its pixels.
const locate = (url, name) => {
  const image = path.join(temp, `${name}.jpg`);
  fs.writeFileSync(image, fs.readFileSync(new URL(url)));
  return JSON.parse(execFileSync(fixture, ['--locate-image', image], { encoding: 'utf8' }));
};

globalThis.nodeRepl = {
  env: process.env, requestMeta: {},
  nativePipe: { createConnection: socketPath => new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    socket.once('connect', () => resolve(socket));
    socket.once('error', reject);
  }) },
};
const { MacComputerUseClient } = await import('./support/js-client/client.js');
const report = message => console.log(`PASS ${message}`);

let service;
try {
  await until(() => events().find(event => event.event === 'ready'), 'fixture ready');

  // "fit" is the ACUA default (point-normalized); "native" keeps every pixel.
  const sizings = { fit: '', native: '[screenshots]\nresolution = "native"\nmax_image_bytes = 0\n' };
  for (const [sizing, configuration] of Object.entries(sizings)) {
    const socket = path.join(temp, `${sizing}.sock`);
    const acuaHome = path.join(temp, `acua-${sizing}`);
    fs.mkdirSync(acuaHome, { recursive: true });
    fs.writeFileSync(path.join(acuaHome, 'config.toml'), configuration);
    service = spawn(serviceTestExecutable(root), [socket], {
      env: serviceTestEnvironment({ CODEX_HOME: path.join(temp, sizing), ACUA_HOME: acuaHome }),
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    service.stderr.on('data', data => process.stderr.write(data));
    await until(() => fs.existsSync(socket), 'service socket');
    nodeRepl.env = { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket };
    const client = new MacComputerUseClient();

    // The session opens on the primary display, then the window moves.
    await client.getAppState(fixtureApp);
    const moved = await command('move-to-other-display', 'moved-to-other-display');
    assert.ok(moved.onOtherDisplay, 'the window did not move to the other display');
    const [otherX, otherY, otherWidth, otherHeight] = moved.displayFrame;
    await windowServerFrameOn([otherX, otherY, otherWidth, otherHeight], 'WindowServer shows the window on the other display');
    fs.writeFileSync(path.join(temp, `${sizing}-moved.json`), JSON.stringify(moved, null, 2));

    const state = await client.getAppState(fixtureApp);
    assert.ok(state.appSnapshot.screenshot?.url, 'the capture on the other display has no screenshot');
    const targets = locate(state.appSnapshot.screenshot.url, `${sizing}-other-display`);
    assert.ok(targets.red && targets.green && targets.blue, `markers missing from the capture: ${JSON.stringify(targets)}`);
    report(`${sizing}: captured the window on display ${moved.displayID} at ${JSON.stringify(moved.displayFrame)}, `
      + `scale ${moved.backingScale} (primary ${moved.primaryScale}); image ${targets.__size.join('×')}`);

    // The capture's own pixels, calibrated against the fixture's global points.
    const toPixel = ([x, y]) => [
      Math.round(targets.red[0] + (x - moved.redScreen[0]) * (targets.blue[0] - targets.red[0]) / (moved.blueScreen[0] - moved.redScreen[0])),
      Math.round(targets.red[1] + (y - moved.redScreen[1]) * (targets.blue[1] - targets.red[1]) / (moved.blueScreen[1] - moved.redScreen[1])),
    ];

    let before = events().length;
    await client.click({ app: fixtureApp, x: targets.green[0], y: targets.green[1] });
    const down = await after(before, event => event.event === 'down', 'click on the other display');
    assert.equal(down.green, true, `the click landed at ${down.x},${down.y}, not on the green target`);
    report(`${sizing}: a screenshot-pixel click on the other display hit its target`);

    before = events().length;
    await client.drag({ app: fixtureApp, fromX: targets.red[0], fromY: targets.red[1], toX: targets.blue[0], toY: targets.blue[1] });
    const up = await after(before, event => event.event === 'up', 'drag release on the other display');
    assert.equal(up.drop, true, `the drag released at ${up.x},${up.y}, off the drop target`);
    report(`${sizing}: a screenshot-pixel drag on the other display reached the drop target`);

    before = events().length;
    await client.scroll({ app: fixtureApp, x: targets.green[0], y: targets.green[1], direction: 'down', pages: 1 });
    const scroll = await after(before, event => event.event === 'scroll', 'scroll on the other display');
    assert.equal(scroll.green, true, 'the scroll did not reach the green target');
    report(`${sizing}: scrolling on the other display used the same image coordinates`);

    const slider = await command('slider-reset', 'slider-ready');
    const [fromX, fromY] = toPixel(slider.from);
    const [toX, toY] = toPixel(slider.to);
    await client.drag({ app: fixtureApp, fromX, fromY, toX, toY });
    const sliderStatus = await command('slider-status', 'slider-status');
    assert.ok(Math.abs(sliderStatus.value - 80) <= 5, `the slider ended at ${sliderStatus.value}, expected about 80`);
    report(`${sizing}: a screenshot-pixel drag moved the slider on the other display`);

    // Back on the primary display, the old capture no longer maps: re-read it.
    await command('restore', 'restored');
    await windowServerFrameOn([primaryDisplay.x, primaryDisplay.y, primaryDisplay.width, primaryDisplay.height],
      'WindowServer shows the window back on the primary display');
    const restored = await client.getAppState(fixtureApp);
    const primaryTargets = locate(restored.appSnapshot.screenshot.url, `${sizing}-primary`);
    before = events().length;
    await client.click({ app: fixtureApp, x: primaryTargets.green[0], y: primaryTargets.green[1] });
    const backDown = await after(before, event => event.event === 'down', 'click back on the primary display');
    assert.equal(backDown.green, true, 'after returning to the primary display the click missed the target');
    report(`${sizing}: back on the primary display, a click after re-reading the window hit its target`);

    for (const transport of client.transports.values()) (await transport).close?.();
    if (service.exitCode === null && service.signalCode === null) {
      const stopped = once(service, 'exit');
      service.kill('SIGTERM');
      await stopped;
    }
    service = undefined;
  }
  console.log(`ALL OTHER-DISPLAY CHECKS PASSED — artifacts: ${temp}`);
} finally {
  service?.kill('SIGTERM');
  fixtureProcess.kill('SIGTERM');
}
