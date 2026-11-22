// Integration test of ComputerUseIPCAppApprovalRequest against the real
// service, over the socket wire. This is the approval the MCP helper asks the
// service for when its MCP client does not support elicitation.
//
// Every case here is decided without the native dialog: an app in
// [apps].allow is pre-approved, and policy refusals fail before any dialog.
// A dialog would block the request for 110 s, so the 15 s reply timeout also
// catches one opening by mistake. The dialog itself is covered by the unit
// tests (make acua-app-approval-test) with a fake.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {serviceTestEnvironment, serviceTestExecutable} from './service-test-environment.mjs';

const ALLOWED_APP = 'com.apple.TextEdit';
// Calculator's real identifier is com.apple.calculator: the deny list must
// match without case, as Launch Services does.
const DENIED_APP = 'com.apple.Calculator';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-approval-'));
const acuaHome = path.join(directory, 'acua');
const configuration = path.join(acuaHome, 'config.toml');
fs.mkdirSync(acuaHome);
const writeConfiguration = text => fs.writeFileSync(configuration, text);
writeConfiguration(`[apps]\nallow = ["${ALLOWED_APP}"]\ndeny = ["${DENIED_APP}"]\n`);

const endpoint = path.join(directory, 'service.sock');
const service = spawn(serviceTestExecutable(root), [endpoint], {
  env: serviceTestEnvironment({ACUA_HOME: acuaHome, CODEX_HOME: path.join(directory, 'codex')}),
  stdio: ['ignore', 'ignore', 'pipe'],
});
let errors = '';
service.stderr.on('data', chunk => errors += chunk);

let socket;
try {
  const deadline = Date.now() + 10000;
  while (!fs.existsSync(endpoint)) {
    assert.ok(Date.now() < deadline && service.exitCode === null, `service did not start: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }

  socket = net.createConnection(endpoint);
  await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });

  let data = Buffer.alloc(0);
  const replies = [];
  socket.on('data', chunk => {
    data = Buffer.concat([data, chunk]);
    while (data.length >= 4 && data.length >= data.readUInt32LE() + 4) {
      const length = data.readUInt32LE();
      replies.push(JSON.parse(data.subarray(4, length + 4)));
      data = data.subarray(length + 4);
    }
  });

  let id = 0;
  async function approve(app) {
    const params = {clientApiVersion: 'AcuaComputerUseIPC-5', requestType: 'ComputerUseIPCAppApprovalRequest', request: {app}};
    const message = Buffer.from(JSON.stringify({id: ++id, jsonrpc: '2.0', method: 'request', params}));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(message.length);
    socket.write(Buffer.concat([header, message]));

    const until = Date.now() + 15000;
    while (!replies.length) {
      assert.ok(Date.now() < until, `approval of ${app} got no reply (a dialog may have opened): ${errors}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    return replies.shift();
  }

  const listed = await approve(ALLOWED_APP);
  assert.deepEqual(listed.result, {decision: 'pre_approved'}, JSON.stringify(listed));
  console.log('PASS an app in [apps].allow is pre-approved without a dialog');

  const denied = await approve(DENIED_APP);
  assert.equal(denied.result, undefined, JSON.stringify(denied));
  assert.match(denied.error?.message ?? '', /blocked|not allowed|policy/i, JSON.stringify(denied));
  console.log('PASS an app in [apps].deny is refused by policy without a dialog');

  const unknown = await approve('com.aex.computeruse.never-installed');
  assert.equal(unknown.result, undefined, JSON.stringify(unknown));
  assert.match(unknown.error?.message ?? '', /Invalid app/, JSON.stringify(unknown));
  console.log('PASS an unknown app is refused without a dialog');

  // The configuration is read on every request, as for the policy.
  writeConfiguration(`[apps]\nenabled = false\nallow = ["${ALLOWED_APP}"]\n`);
  const disabled = await approve(ALLOWED_APP);
  assert.equal(disabled.result, undefined, JSON.stringify(disabled));
  console.log('PASS turning computer use off applies to the next approval');

  writeConfiguration('[apps]\nallow = "not a list"\n');
  const invalid = await approve(ALLOWED_APP);
  assert.equal(invalid.result, undefined, JSON.stringify(invalid));
  assert.match(invalid.error?.message ?? '', /configuration is invalid/, JSON.stringify(invalid));
  console.log('PASS an invalid configuration fails closed');

  writeConfiguration(`[apps]\nallow = ["${ALLOWED_APP}"]\n`);
  assert.deepEqual((await approve(ALLOWED_APP)).result, {decision: 'pre_approved'});
  console.log('PASS a fixed configuration pre-approves again');

  assert.equal(fs.readFileSync(configuration, 'utf8'), `[apps]\nallow = ["${ALLOWED_APP}"]\n`, 'the service never rewrites config.toml');
  console.log('PASS the service never writes config.toml');
} finally {
  socket?.destroy();
  service.kill();
  fs.rmSync(directory, {recursive: true, force: true});
}
