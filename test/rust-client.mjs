import { serviceTestEnvironment, serviceTestExecutable, serviceTestRustManifest, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const manifest = serviceTestRustManifest(root);
execFileSync('cargo', ['build', '--offline', '--locked', '--manifest-path', manifest, '--example', 'native_fixture'], { stdio: 'inherit' });
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ['--diagnostics'], { encoding: 'utf8' }));
assert.ok(!diagnostics.screenLocked && diagnostics.accessibility && diagnostics.screenRecording, 'Rust native test requires an unlocked, permitted desktop');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-rust-'));
const app = path.join(temp, 'RustFixture.app'), macos = path.join(app, 'Contents/MacOS');
fs.mkdirSync(macos, { recursive: true });
const bundle = uniqueFixtureBundle('test.acua.rust-fixture'), binary = path.join(macos, 'RustFixture');
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>RustFixture</string><key>CFBundleName</key><string>RustFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/InputFixture.swift'), '-o', binary], { stdio: 'inherit' });
execFileSync('codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
const socket = path.join(temp, 'service.sock');
const fixture = spawn(binary, [temp], { stdio: ['ignore', 'ignore', 'inherit'] });
// The service creates only numbered collision folders, never this base folder.
fs.mkdirSync(path.join(temp, 'screenshots'), { recursive: true });
const service = spawn(serviceTestExecutable(root), [socket], {
  env: serviceTestEnvironment({ CODEX_HOME: temp, ACUA_SCREENSHOT_DIRECTORY: path.join(temp, 'screenshots') }),
  stdio: ['ignore', 'ignore', 'inherit'],
});
try {
  const end = Date.now() + 10000;
  while (!(fs.existsSync(socket) && fs.existsSync(path.join(temp, 'events.jsonl')) && fs.readFileSync(path.join(temp, 'events.jsonl'), 'utf8').includes('"ready"'))) {
    assert.ok(Date.now() < end, `Rust fixture startup timed out; ${temp}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  const cargoTarget = process.env.CARGO_TARGET_DIR || path.join(path.dirname(manifest), 'target');
  const probe = spawn(path.join(cargoTarget, 'debug/examples/native_fixture'), [socket, temp, bundle, String(fixture.pid), fixtureAppTarget(app)], { stdio: 'inherit' });
  const timer = setTimeout(() => probe.kill('SIGTERM'), 90000);
  try {
    const result = await new Promise((resolve, reject) => { probe.once('error', reject); probe.once('exit', (code, signal) => resolve({ code, signal })); });
    assert.equal(result.code, 0, `Rust native probe failed (${result.signal ?? result.code}); ${temp}`);
  } finally { clearTimeout(timer); }
  console.log(`RUST CLIENT NATIVE INTEGRATION PASSED — artifacts: ${temp}`);
} finally {
  for (const child of [service, fixture]) child.kill('SIGTERM');
}
