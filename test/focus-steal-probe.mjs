import { publishFixtureCommand } from './fixture-command.mjs';
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
const results = [];
let observer;
try {
  const target = await fixture('steal-target'), foreground = await fixture('steal-foreground');
  await until(() => invoke('inspect', foreground).actualFrontmostPID === foreground.process.pid, 'foreground ready');
  observer = spawn('/tmp/cua-keyboard-focus-notifications', ['30', '--all-notifications', `--ready-file=${path.join(temp, 'observer.ready')}`], { stdio: ['ignore', fs.openSync(path.join(temp, 'notifications.json'), 'w'), 'inherit'] });
  const observed = new Promise((resolve, reject) => { observer.once('exit', code => code === 0 ? resolve() : reject(new Error(`observer exit ${code}`))); });
  await until(() => fs.existsSync(path.join(temp, 'observer.ready')), 'observer tap installed');
  results.push({ step: 'before', target: invoke('inspect', target), foreground: invoke('inspect', foreground) });
  for (const command of ['nonactivating-panel', 'close-panel']) {
    publishFixtureCommand(path.join(target.directory, 'command'), command);
    await pause(350);
    results.push({ step: command, target: invoke('inspect', target), targetState: await state(target) });
  }
  execFileSync(probe, ['activate', String(foreground.process.pid)]);
  await pause(350);
  results.push({ step: 'restored', foreground: invoke('inspect', foreground) });
  await observed;
  fs.writeFileSync(path.join(temp, 'results.json'), JSON.stringify(results, null, 2));
  const notifications = JSON.parse(fs.readFileSync(path.join(temp, 'notifications.json'), 'utf8'));
  const subtypeCounts = {};
  for (const event of notifications.records) subtypeCounts[event.subtype64] = (subtypeCounts[event.subtype64] ?? 0) + 1;
  console.log(JSON.stringify({ artifacts: temp, results, notifications: notifications.records.length, subtypeCounts }, null, 2));
} finally { observer?.kill('SIGTERM'); for (const process of processes) process.kill('SIGTERM'); }
