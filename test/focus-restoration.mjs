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
  while (Date.now() < end) { const value = await body(); if (value) return value; await pause(20); }
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
let passed = 0;
const check = (name, ok) => { assert.ok(ok, name); passed++; console.log(`PASS ${name}`); };
const results = [];
try {
  const target = await fixture('restore-target'), foreground = await fixture('restore-foreground'), third = await fixture('restore-third');
  const activate = async app => {
    execFileSync(probe, ['activate', String(app.process.pid)]);
    await until(() => invoke('inspect', app).actualFrontmostPID === app.process.pid, 'activate selected fixture');
  };
  for (const mode of ['success', 'foreign-key', 'operation-error', 'deadline', 'third-app', 'window-order', 'target-exit']) {
    await activate(foreground);
    const targetBefore = await state(target), foregroundBefore = await state(foreground);
    const result = JSON.parse(execFileSync('/tmp/cua-focus-restoration-native', [mode, String(target.process.pid), String(foreground.process.pid), foreground.directory, String(third.process.pid), target.directory], { encoding: 'utf8', timeout: 8000 }));
    results.push(result); fs.writeFileSync(path.join(temp, 'results.json'), JSON.stringify(results, null, 2));
    check(`${mode}: WindowServer updates are reenabled`, result.leasesDuringOperation === 1 && result.leasesAfterCompletion === 0);
    if (['success', 'window-order', 'foreign-key'].includes(mode)) {
      check(`${mode}: forced foreground activation is restored`, result.success && result.targetReallyBecameForeground && result.actualFrontmostPID === foreground.process.pid);
    } else if (mode === 'operation-error') check('operation error is propagated after restoration', result.error === 'operationFault' && result.actualFrontmostPID === foreground.process.pid);
    else if (mode === 'deadline') check('deadline failure releases the update lease', result.errorCode === -10005);
    else if (mode === 'third-app') check('a third foreground app is preserved instead of being overridden', result.errorCode === -10016 && result.actualFrontmostPID === third.process.pid);
    else if (mode === 'target-exit') check('target termination is reported without leaking the update suspension', result.errorCode === -10007);
    if (!['third-app', 'target-exit'].includes(mode)) await until(() => invoke('inspect', foreground).actualFrontmostPID === foreground.process.pid, `${mode} previous foreground recovered`);
    if (mode === 'third-app') {
      await until(async () => !(await state(foreground)).isActive, 'previous receiver deactivated after third app wins');
      check('the previous foreground receiver does not retain invented activation after a third app wins', true);
    }
    if (mode === 'window-order') check('displaced foreground window ordering is restored', result.orderWasDisplaced && result.windowOrderRestored);
    if (mode === 'foreign-key') {
      await until(async () => (await state(foreground)).text === foregroundBefore.text + 'q', 'foreign key redirected to foreground editor');
      check('foreign key is delivered to the foreground editor, not the receiver', (await state(target)).text === targetBefore.text);
    }
  }
  console.log(`ALL ${passed} NATIVE FOCUS RESTORATION CHECKS PASSED — artifacts: ${temp}`);
} finally { for (const process of processes) process.kill('SIGTERM'); }
