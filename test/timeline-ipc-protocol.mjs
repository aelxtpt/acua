import os from 'node:os';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-timeline-ipc-'));
const socket = path.join(directory, 'service.sock');
// Timeline keeps its settings and memory resources in ACUA's directory. A
// separate CODEX_HOME proves nothing is written to Codex's directory anymore.
const acuaHome = path.join(directory, 'acua');
const codexHome = path.join(directory, 'codex');
fs.mkdirSync(codexHome, {recursive: true});
const child = spawn(serviceTestExecutable(root), [socket], {
  env: serviceTestEnvironment({ACUA_HOME: acuaHome, CODEX_HOME: codexHome}), stdio: ['ignore', 'ignore', 'inherit'],
});
const pass = label => console.log('PASS ' + label);
try {
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(socket)) {
    assert.equal(child.exitCode, null, 'Service exited before accepting requests');
    assert.ok(Date.now() < deadline, 'Timeline IPC socket unavailable');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  globalThis.nodeRepl = {
    env: {ACUA_SERVICE_NATIVE_PIPE_PATH: socket}, requestMeta: {},
    nativePipe: {createConnection: name => new Promise((resolve, reject) => {
      const connection = net.createConnection(name);
      connection.once('connect', () => resolve(connection));
      connection.once('error', reject);
    })},
  };
  const {MacComputerUseClient} = await import('./support/js-client/client.js');
  const client = new MacComputerUseClient();
  const request = (suffix, body = {}) => client.request('ComputerUseIPCTimeline' + suffix + 'Request', body);
  const status = await request('Status');
  assert.equal(status.state, 'stopped');
  assert.equal(status.currentSegmentEventsPath, undefined);
  assert.deepEqual(await request('Status', null), status);
  pass('Timeline wire status returns an inactive owner without starting capture');

  const menuRoute = 'ComputerUseIPCStatusItemMenuStateRequest';
  const menu = await client.request(menuRoute, {});
  assert.deepEqual(menu.computerUse, {activeApplications: []});
  assert.deepEqual(menu.computerHistory.recentApplications, []);
  assert.equal(menu.computerHistory.state, 'stopped');
  assert.deepEqual(await client.request(menuRoute, null), menu);
  assert.deepEqual(await client.request(menuRoute, ['unused']), menu);
  await assert.rejects(client.request(menuRoute, undefined), error => error.code === -32602 && error.message === 'Invalid params');
  pass('status menu returns an empty live session snapshot and handles native empty request forms');

  const defaults = {observation: {
    defaultApplicationBehavior: 'observe', defaultURLBehavior: 'observe', allowlist: [], blocklist: [],
  }};
  assert.deepEqual(await request('GetSettings'), defaults);
  assert.equal(fs.existsSync(path.join(acuaHome, 'timeline', 'settings.json')), false);
  pass('Timeline wire getSettings reads defaults without creating files');

  assert.deepEqual(await request('Stop'), status);
  for (const suffix of ['Pause', 'Resume']) {
    await assert.rejects(request(suffix), error => error.code === -10005 && /Computer History is stopped/.test(error.message));
  }
  await assert.rejects(client.request('ComputerUseIPCTimelineStartRequest', undefined), error => error.code === -32602 && error.message === 'Invalid params');
  pass('Timeline wire rejects invalid transitions and missing start data');

  const updated = {observation: {...defaults.observation, defaultURLBehavior: 'do_not_observe'}};
  assert.deepEqual(await request('UpdateSettings', {settings: updated}), updated);
  const target = {scope: 'url', urlDomain: 'OWNED.EXAMPLE'};
  const ruleSettings = await request('UpdateObservationPolicy', {target, observe: true});
  assert.deepEqual(ruleSettings.observation.allowlist, [{scope: 'url', urlDomain: 'owned.example'}]);
  const saved = JSON.parse(fs.readFileSync(path.join(acuaHome, 'timeline', 'settings.json')));
  assert.deepEqual(saved, ruleSettings);
  assert.deepEqual(await request('GetSettings'), saved);
  pass('Timeline wire settings and policy update persist and read back');

  const resources = path.join(acuaHome, 'memories', 'extensions', 'timeline', 'resources');
  fs.mkdirSync(resources, {recursive: true});
  const timestamp = new Date(Date.now() - 2000).toISOString().slice(0, 19).replaceAll(':', '-');
  const summary = path.join(resources, timestamp + '-10min-owned.md');
  fs.writeFileSync(summary, '# Owned history fixture\n');
  const menuWithHistory = await client.request(menuRoute, {});
  assert.equal(menuWithHistory.computerHistory.canClearHistory.lastTenMinutes, true);
  assert.equal(menuWithHistory.computerHistory.canClearHistory.lastHour, true);
  assert.ok(fs.existsSync(summary));
  pass('status menu reports history in the fixture while stopped');

  await assert.rejects(request('ClearHistory', {scope: 'interval'}), error => error.code === -10005);
  await assert.rejects(request('ClearHistory', {scope: 'unknown'}), error => error.code === -32602 && error.message === 'Invalid params');
  await assert.rejects(request('Pause', {duration: 'invalid'}), error => error.code === -32602 && error.message === 'Invalid params');
  pass('Timeline wire distinguishes invalid intervals from undecodable requests');
  assert.deepEqual(await request('Status'), status);
  pass('Timeline wire validation errors preserve the connection');
  assert.deepEqual(fs.readdirSync(codexHome), []);
  pass('Timeline writes nothing to CODEX_HOME');
} finally {
  child.kill('SIGTERM');
  await new Promise(resolve => {
    if (child.exitCode !== null || child.signalCode !== null) resolve();
    else child.once('exit', resolve);
  });
  fs.rmSync(directory, {recursive: true, force: true});
}
