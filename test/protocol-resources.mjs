import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
// Real service socket, production 30-second deadline and 128-client limit.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-protocol-resources-'));
const socketPath = path.join(temp, 'service.sock');
const service = spawn(serviceTestExecutable(root), [socketPath], { env: serviceTestEnvironment(), stdio: ['ignore', 'ignore', 'pipe'] });
let errors = '';
service.stderr.on('data', data => { errors += data; });
const peers = new Set();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const ping = Buffer.from(JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'ping', params: { clientApiVersion: 'AcuaComputerUseIPC-5' } }));
const frame = body => { const header = Buffer.alloc(4); header.writeUInt32LE(body.length); return Buffer.concat([header, body]); };
const pass = label => console.log(`PASS ${label}`);
async function until(test, label, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (test()) return; await pause(10); }
  throw new Error(`Timeout: ${label}; artifacts ${temp}; ${errors}`);
}
async function connect() {
  const stream = net.createConnection({ path: socketPath });
  const peer = { stream, closed: false, bytes: Buffer.alloc(0), closedAt: 0 };
  peers.add(peer);
  stream.on('data', data => { peer.bytes = Buffer.concat([peer.bytes, data]); });
  stream.on('close', () => { peer.closed = true; peer.closedAt = Date.now(); });
  stream.on('error', () => {});
  await new Promise((resolve, reject) => { stream.once('connect', resolve); stream.once('error', reject); });
  return peer;
}
async function roundtrip(peer) {
  const before = peer.bytes.length;
  peer.stream.write(frame(ping));
  await until(() => {
    const received = peer.bytes.subarray(before);
    return received.length >= 4 && received.length >= 4 + received.readUInt32LE();
  }, 'ping reply');
  const received = peer.bytes.subarray(before);
  assert.equal(JSON.parse(received.subarray(4, 4 + received.readUInt32LE())).result.serverApiVersion, 'AcuaComputerUseIPC-5');
}
try {
  await until(() => fs.existsSync(socketPath), 'service ready');
  const started = Date.now();
  const idle = await connect();
  await roundtrip(idle);
  const partialHeader = await connect();
  partialHeader.stream.write(Buffer.from([8, 0]));
  const partialBody = await connect();
  partialBody.stream.write(Buffer.from([8, 0, 0, 0, 123]));
  const held = [];
  for (let i = 0; i < 125; i++) {
    const peer = await connect();
    await roundtrip(peer);
    held.push(peer);
  }
  pass('128 simultaneous clients complete the handshake');
  const rejected = await connect();
  await until(() => rejected.closed, '129th connection rejected');
  assert.equal(rejected.bytes.length, 0);
  pass('129th client is closed without a response');
  held.pop().stream.destroy();
  // A connected socket can already be closed by the server before Node sees
  // close, so retry until the server has retired the previous worker.
  await pause(50);
  const replacement = await connect();
  await roundtrip(replacement);
  pass('a slot becomes reusable after client disconnect');
  replacement.stream.destroy();
  for (const peer of held) peer.stream.destroy();
  await until(() => idle.closed && partialHeader.closed && partialBody.closed, 'whole-frame production deadlines', 34_000);
  for (const [label, peer] of [['idle', idle], ['partial header', partialHeader], ['partial body', partialBody]]) {
    assert.ok(peer.closedAt - started >= 29_000, `${label} closed too early`);
    assert.ok(peer.closedAt - started < 34_000, `${label} exceeded timeout`);
    pass(`${label} connection expires on the production 30-second deadline`);
  }
  const after = await connect();
  await roundtrip(after);
  assert.equal(service.exitCode, null);
  pass('service accepts requests after timed-out clients are retired');
  console.log(`ALL RESOURCE INTEGRATION CHECKS PASSED — artifacts: ${temp}`);
} finally {
  for (const peer of peers) peer.stream.destroy();
  service.kill('SIGTERM');
}
