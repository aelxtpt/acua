// Integration test of [screenshots].resolution and max_image_bytes against the
// real service and a worst-case window: it fills the screen with labelled
// buttons over noise that compresses poorly. It needs Screen Recording and
// Accessibility and it clicks, so it runs with the physical batches.
//
// - The default image is fitted (2048 x 768 at most) and within the byte limit.
// - A PNG over the limit falls back to JPEG, and the reported MIME type
//   matches the file's bytes.
// - "native" keeps every backing pixel; the limit then lowers JPEG quality,
//   never the pixel size.
// - In the fitted default, a click at a button's centre in image pixels
//   presses that button: the smaller image keeps coordinates right.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget} from './service-test-environment.mjs';

const DEFAULT_MAX_IMAGE_BYTES = 750_000;
const FIT_LONG_EDGE = 2048;
const FIT_SHORT_EDGE = 768;

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ['--diagnostics'], {encoding: 'utf8'}));
assert.ok(!diagnostics.screenLocked && diagnostics.accessibility && diagnostics.screenRecording,
  'screenshot limits need an unlocked desktop with Accessibility and Screen Recording');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-screenshot-limits-'));
const bundle = uniqueFixtureBundle('com.aex.computeruse.screenshot-size-fixture');
const app = path.join(temp, 'ScreenshotSizeFixture.app');
const binary = path.join(app, 'Contents/MacOS/ScreenshotSizeFixture');
fs.mkdirSync(path.dirname(binary), {recursive: true});
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>ScreenshotSizeFixture</string>
<key>CFBundleName</key><string>ScreenshotSizeFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/ScreenshotSizeFixture.swift'), '-o', binary], {stdio: 'inherit'});
execFileSync('codesign', ['--force', '--sign', '-', app], {stdio: 'inherit'});
const fixtureApp = fixtureAppTarget(app);

const events = () => {
  try { return fs.readFileSync(path.join(temp, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); }
  catch { return []; }
};
async function until(condition, label, ms = 10000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = condition();
    if (value)
      return value;
    assert.ok(Date.now() < deadline, `timeout: ${label}`);
    await new Promise(resolve => setTimeout(resolve, 40));
  }
}

// The image's own bytes, independent of what the service reports.
function inspect(url) {
  const bytes = fs.readFileSync(decodeURIComponent(new URL(url).pathname));
  if (bytes[0] === 0x89 && bytes.toString('latin1', 1, 4) === 'PNG')
    return {mimeType: 'image/png', width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), byteCount: bytes.length};

  assert.ok(bytes[0] === 0xFF && bytes[1] === 0xD8, 'the screenshot is neither PNG nor JPEG');
  for (let offset = 2; offset < bytes.length;) {
    const marker = bytes[offset + 1];
    if (marker >= 0xC0 && marker <= 0xC2)
      return {mimeType: 'image/jpeg', width: bytes.readUInt16BE(offset + 7), height: bytes.readUInt16BE(offset + 5), byteCount: bytes.length};
    offset += 2 + bytes.readUInt16BE(offset + 2);
  }
  throw new Error('JPEG without a frame header');
}

globalThis.nodeRepl = {
  env: process.env, requestMeta: {},
  nativePipe: {createConnection: socketPath => new Promise((resolve, reject) => {
    const socket = net.createConnection({path: socketPath});
    socket.once('connect', () => resolve(socket));
    socket.once('error', reject);
  })},
};
const {MacComputerUseClient} = await import('./support/js-client/client.js');

const fixture = spawn(binary, [temp], {stdio: ['ignore', 'ignore', 'inherit']});
let service;

// One service per configuration, so each reads its own config.toml.
async function withService(label, config, body) {
  const acuaHome = path.join(temp, `acua-${label}`);
  fs.mkdirSync(acuaHome, {recursive: true});
  fs.writeFileSync(path.join(acuaHome, 'config.toml'), config);
  const socket = path.join(temp, `${label}.sock`);
  service = spawn(serviceTestExecutable(root), [socket], {
    env: serviceTestEnvironment({ACUA_HOME: acuaHome, CODEX_HOME: path.join(temp, `codex-${label}`)}),
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let errors = '';
  service.stderr.on('data', chunk => errors += chunk);
  try {
    await until(() => fs.existsSync(socket), `${label} service socket`);
    nodeRepl.env = {...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket};
    await body(new MacComputerUseClient());
  } catch (error) {
    error.message += `\n${errors.slice(-2000)}`;
    throw error;
  } finally {
    // SIGTERM lets the suite's launcher trace the service exit.
    const exited = new Promise(resolve => service.exitCode !== null ? resolve() : service.once('exit', resolve));
    service.kill();
    await exited;
  }
}

try {
  const ready = await until(() => events().find(event => event.event === 'ready'), 'fixture ready');
  const nativeWidth = Math.round(ready.windowWidth * ready.backingScale);

  await withService('fit', '', async client => {
    const shot = (await client.getAppState(fixtureApp)).appSnapshot;
    const image = inspect(shot.screenshot.url);
    assert.equal(shot.screenshot.mimeType, image.mimeType);
    assert.ok(Math.max(image.width, image.height) <= FIT_LONG_EDGE && Math.min(image.width, image.height) <= FIT_SHORT_EDGE,
      `default image ${image.width}x${image.height} is not fitted`);
    assert.ok(image.byteCount <= DEFAULT_MAX_IMAGE_BYTES, `default image is ${image.byteCount} bytes`);
    const base64Result = Math.ceil(image.byteCount / 3) * 4 + Buffer.byteLength(shot.text);
    assert.ok(base64Result < 1024 * 1024, `the image and text are ${base64Result} bytes in an MCP result`);
    console.log(`PASS the default screenshot is ${image.width}x${image.height}, ${image.byteCount} bytes, ${base64Result} in an MCP result`);

    // Image pixels per window point; the title bar is above the content.
    const scale = image.width / ready.windowWidth;
    const titleBar = ready.windowHeight - ready.contentHeight;
    const cellWidth = ready.contentWidth / ready.columns;
    const cellHeight = ready.contentHeight / ready.rows;
    const corners = [[0, 0], [ready.columns - 1, ready.rows - 1], [Math.floor(ready.columns / 2), Math.floor(ready.rows / 2)]];
    for (const [column, row] of corners) {
      const tag = row * ready.columns + column;
      const before = events().length;
      await client.click({app: fixtureApp, x: Math.round((column + 0.5) * cellWidth * scale),
                          y: Math.round((titleBar + (row + 0.5) * cellHeight) * scale)});
      const pressed = await until(() => events().slice(before).find(event => event.event === 'pressed'), `press of button ${tag}`);
      assert.equal(pressed.tag, tag, `a click at button ${tag}'s image centre pressed button ${pressed.tag}`);
    }
    console.log('PASS clicks at image coordinates of the fitted screenshot press the buttons drawn there');
  });

  await withService('png', '[screenshots]\nformat = "png"\n', async client => {
    const shot = (await client.getAppState(fixtureApp)).appSnapshot;
    const image = inspect(shot.screenshot.url);
    assert.equal(image.mimeType, 'image/jpeg', 'the noisy PNG is over the limit and falls back to JPEG');
    assert.equal(shot.screenshot.mimeType, image.mimeType, 'the reported MIME type follows the fallback');
    assert.ok(image.byteCount <= DEFAULT_MAX_IMAGE_BYTES);
    console.log(`PASS a PNG over the limit is sent as JPEG and reported as ${shot.screenshot.mimeType}`);
  });

  await withService('native-unlimited', '[screenshots]\nresolution = "native"\nmax_image_bytes = 0\n', async client => {
    const image = inspect((await client.getAppState(fixtureApp)).appSnapshot.screenshot.url);
    assert.equal(image.width, nativeWidth, 'native keeps every backing pixel');
    console.log(`PASS resolution "native" keeps every backing pixel: ${image.width}x${image.height}, ${image.byteCount} bytes`);
  });

  await withService('native-limited', '[screenshots]\nresolution = "native"\nmax_image_bytes = 750000\n', async client => {
    const image = inspect((await client.getAppState(fixtureApp)).appSnapshot.screenshot.url);
    assert.equal(image.width, nativeWidth, 'the limit never changes the pixel size');
    assert.ok(image.byteCount <= DEFAULT_MAX_IMAGE_BYTES, `limited native image is ${image.byteCount} bytes`);
    console.log(`PASS the limit lowers JPEG quality, not resolution: ${image.width}x${image.height}, ${image.byteCount} bytes`);
  });
} finally {
  fixture.kill();
  fs.rmSync(temp, {recursive: true, force: true});
}
