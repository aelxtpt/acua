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
try {
  const target = await fixture('prevent-target'), foreground = await fixture('prevent-foreground');
  const beforeReset = events(foreground.directory).length;
  publishFixtureCommand(path.join(foreground.directory, 'command'), 'reset');
  await until(() => events(foreground.directory).slice(beforeReset).find(e => e.event === 'reset'), 'foreground editor selected');
  execFileSync(probe, ['activate', String(foreground.process.pid)]);
  await until(async () => {
    const observed = invoke('inspect', foreground), editor = await state(foreground);
    return observed.actualFrontmostPID === foreground.process.pid && observed.keyboardFocusPID === foreground.process.pid &&
      editor.isActive && editor.keyWindow === foreground.ready.window;
  }, 'foreground fixture owns real keyboard focus and its selected editor');
  execFileSync('/tmp/cua-focus-preventer-native', [String(target.process.pid), String(foreground.process.pid), target.directory, foreground.directory], { stdio: 'inherit', timeout: 25000 });
  console.log(`NATIVE PERSISTENT FOCUS FILTERS PASSED — artifacts: ${temp}`);
} finally { for (const process of processes) process.kill('SIGTERM'); }
