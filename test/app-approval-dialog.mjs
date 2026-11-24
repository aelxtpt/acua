// Integration test of the service's approval dialog lifetime, against the real
// service over the socket wire. It opens a real dialog, so it runs with the
// physical batches; it never clicks or types.
//
// The XPC and socket layers do not cancel a running request when its client
// exits, and main-queue blocks do not run inside the dialog's modal loop. The
// dialog must still close once the client that asked is gone, and a request
// queued behind it from a dead client must never open a second dialog.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {serviceTestEnvironment, serviceTestExecutable} from './service-test-environment.mjs';

// Not in [apps].allow, so the service asks the user.
const UNLISTED_APP = 'com.apple.TextEdit';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-approval-dialog-'));
const acuaHome = path.join(directory, 'acua');
fs.mkdirSync(acuaHome);
fs.writeFileSync(path.join(acuaHome, 'config.toml'), '[apps]\n');

const windowCounter = path.join(directory, 'ServiceWindows');
execFileSync('swiftc', ['-O', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/ServiceWindows.swift'), '-o', windowCounter], {stdio: 'inherit'});

// A separate process per request, so the test can kill the requester.
const requester = path.join(directory, 'requester.mjs');
fs.writeFileSync(requester, `
import net from 'node:net';
const socket = net.createConnection(process.argv[2], () => {
  const params = {clientApiVersion: 'AcuaComputerUseIPC-5', requestType: 'ComputerUseIPCAppApprovalRequest', request: {app: process.argv[3]}};
  const message = Buffer.from(JSON.stringify({id: 1, jsonrpc: '2.0', method: 'request', params}));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(message.length);
  socket.write(Buffer.concat([header, message]));
});
socket.on('data', () => process.exit(0));
`);

const endpoint = path.join(directory, 'service.sock');
const service = spawn(serviceTestExecutable(root), [endpoint], {
  env: serviceTestEnvironment({ACUA_HOME: acuaHome, CODEX_HOME: path.join(directory, 'codex')}),
  stdio: ['ignore', 'ignore', 'pipe'],
});
let errors = '';
service.stderr.on('data', chunk => errors += chunk);

const serviceWindows = () => Number(execFileSync(windowCounter, [String(service.pid)], {encoding: 'utf8'}).trim());

async function waitFor(description, condition, seconds) {
  const until = Date.now() + seconds * 1000;
  while (!condition()) {
    assert.ok(Date.now() < until, `${description}: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
}

const requesters = [];
try {
  await waitFor('service did not start', () => fs.existsSync(endpoint), 10);
  assert.equal(serviceWindows(), 0, 'no dialog before any approval request');

  const first = spawn(process.execPath, [requester, endpoint, UNLISTED_APP], {stdio: 'ignore'});
  requesters.push(first);
  await waitFor('the approval dialog never opened', () => serviceWindows() > 0, 10);
  console.log('PASS an unlisted app opens the service dialog');

  // Queued behind the open dialog; its client dies before its turn.
  const queued = spawn(process.execPath, [requester, endpoint, UNLISTED_APP], {stdio: 'ignore'});
  requesters.push(queued);
  await new Promise(resolve => setTimeout(resolve, 1000));
  queued.kill('SIGKILL');
  first.kill('SIGKILL');

  await waitFor('the dialog stayed open after its client exited', () => serviceWindows() === 0, 5);
  console.log('PASS the dialog closes once its client exits');

  // The dead queued request must not open a dialog of its own.
  await new Promise(resolve => setTimeout(resolve, 2000));
  assert.equal(serviceWindows(), 0, 'a request from a dead client opened a dialog');
  console.log('PASS a queued request from a dead client never opens a dialog');
} finally {
  requesters.forEach(child => child.kill('SIGKILL'));
  // SIGTERM lets the suite's launcher trace the service exit.
  const exited = new Promise(resolve => service.exitCode !== null ? resolve() : service.once('exit', resolve));
  service.kill();
  await exited;
  fs.rmSync(directory, {recursive: true, force: true});
}
