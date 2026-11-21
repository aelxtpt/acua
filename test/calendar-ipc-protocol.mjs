import os from 'node:os';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-calendar-ipc-'));
const socket = path.join(directory, 'service.sock');
const child = spawn(serviceTestExecutable(root), [socket], {
  env: serviceTestEnvironment(), stdio: ['ignore', 'ignore', 'inherit'],
});
try {
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(socket)) {
    assert.equal(child.exitCode, null, 'Service exited before accepting requests');
    assert.ok(Date.now() < deadline, 'Calendar IPC socket unavailable');
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
  for (const operation of ['ListCalendars', 'ListEvents', 'GetEvent', 'CreateEvent', 'UpdateEvent', 'DeleteEvent']) {
    const route = 'ComputerUseIPCCalendar' + operation + 'Request';
    // Reject before permission presentation or store creation.
    const body = operation === 'ListCalendars' ? undefined : {};
    await assert.rejects(client.request(route, body), error => error.code === -32602 && error.message === 'Invalid params');
    console.log('PASS Calendar socket dispatch validates ' + operation);
  }
  const apps = await client.request('ComputerUseIPCListAppsRequest', {});
  assert.ok(Array.isArray(apps));
  console.log('PASS Calendar validation errors preserve the service connection');
} finally {
  child.kill('SIGTERM');
  await new Promise(resolve => {
    if (child.exitCode !== null || child.signalCode !== null) resolve();
    else child.once('exit', resolve);
  });
  fs.rmSync(directory, {recursive: true, force: true});
}
