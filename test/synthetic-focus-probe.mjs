import { publishFixtureCommand } from './fixture-command.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-synthetic-focus-'));
const probe = '/tmp/cua-synthetic-focus-probe';
const executable = path.join(temp, 'InputFixture');
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache', path.join(root, 'test/InputFixture.swift'), '-o', executable], { stdio: 'inherit' });
const processes = [];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(body, label, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const value = body(); if (value) return value; await pause(20); }
  throw new Error(`Timeout ${label}; artifacts ${temp}`);
}
function events(directory) {
  try { return fs.readFileSync(path.join(directory, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch { return []; }
}
async function fixture(name) {
  const directory = path.join(temp, name), app = path.join(directory, 'FocusFixture.app'), macos = path.join(app, 'Contents/MacOS');
  fs.mkdirSync(macos, { recursive: true });
  fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.acua.focus-fixture.${name}</string><key>CFBundleExecutable</key><string>FocusFixture</string><key>CFBundleName</key><string>Focus ${name}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
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
function invoke(mode, fixture, ...args) {
  return JSON.parse(execFileSync(probe, [mode, String(fixture.process.pid), ...args.map(String)], { encoding: 'utf8' }));
}
try {
  const target = await fixture('target');
  const decoy = await fixture('decoy');
  await until(() => invoke('inspect', decoy).actualFrontmostPID === decoy.process.pid, 'decoy frontmost');
  const before = await state(target);
  const activation = invoke('synthetic', target, target.ready.window);
  const activated = await state(target);
  const keyboard = invoke('key', target);
  const after = await state(target);
  const deactivation = invoke('deactivate', target);
  const inactive = await state(target);
  const trace = { targetPID: target.process.pid, decoyPID: decoy.process.pid,
    before: { active: before.isActive, keyWindow: before.keyWindow, frontmostPID: before.frontmostPID },
    activation, activated: { active: activated.isActive, keyWindow: activated.keyWindow, frontmostPID: activated.frontmostPID },
    keyboard, selection: after.selection, expectedSelection: [0, after.text.length],
    deactivation, inactive: { active: inactive.isActive, keyWindow: inactive.keyWindow, frontmostPID: inactive.frontmostPID } };
  fs.writeFileSync(path.join(temp, 'trace.json'), JSON.stringify(trace, null, 2));
  console.log(JSON.stringify(trace, null, 2));
  assert.deepEqual(after.selection, [0, after.text.length]);
  assert.equal(activation.actualFrontmostPID, decoy.process.pid);
  assert.equal(keyboard.actualFrontmostPID, decoy.process.pid);
  assert.equal(inactive.isActive, false);
  console.log(`ALL SYNTHETIC FOCUS PROBE CHECKS PASSED — artifacts: ${temp}`);
} finally { for (const process of processes) process.kill('SIGTERM'); }
