import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from "node:assert/strict";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "cua-protocol-edge-"));
const socketPath = path.join(temp, "service.sock");
const service = spawn(serviceTestExecutable(root), [socketPath], { env: serviceTestEnvironment(), stdio: ["ignore", "ignore", "pipe"] });
let errors = "";
service.stderr.on("data", data => { errors += data; });
service.on("exit", (code, signal) => { errors += `service exit code=${code} signal=${signal}\n`; });
const version = "AcuaComputerUseIPC-5";
const ping = { id: 1, jsonrpc: "2.0", method: "ping", params: { clientApiVersion: version } };
const frame = value => {
  const data = Buffer.isBuffer(value) ? value : Buffer.from(typeof value === "string" ? value : JSON.stringify(value));
  const header = Buffer.alloc(4); header.writeUInt32LE(data.length);
  return Buffer.concat([header, data]);
};
const request = (type, value, extra = {}) => ({ id: 2, jsonrpc: "2.0", method: "request", params: {
  clientApiVersion: version, requestType: type, request: value, ...extra,
} });
const peers = new Set();
async function connect() {
  const socket = net.createConnection({ path: socketPath });
  peers.add(socket);
  let buffer = Buffer.alloc(0), ended = false;
  const replies = [];
  socket.on("data", data => {
    buffer = Buffer.concat([buffer, data]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE()) {
      const size = buffer.readUInt32LE();
      replies.push(JSON.parse(buffer.subarray(4, size + 4).toString()));
      buffer = buffer.subarray(4 + size);
    }
  });
  socket.on("end", () => { ended = true; });
  socket.on("error", error => { errors += `peer socket error: ${error.message}\n`; });
  await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  async function wait(predicate) {
    const deadline = Date.now() + 4000;
    while (!predicate()) {
      if (Date.now() >= deadline) {
        if (service.exitCode === null && service.signalCode === null) {
          try { execFileSync("sample", [String(service.pid), "1", "-file", path.join(temp, "timeout-sample.txt")], { stdio: "ignore", timeout: 5000 }); }
          catch {}
        }
        assert.fail(`socket response timed out; artifacts ${temp}: ${errors}`);
      }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  }
  return { socket, replies, wait, ended: () => ended };
}
const pass = label => console.log(`PASS ${label}`);
try {
  const end = Date.now() + 8000;
  while (!fs.existsSync(socketPath)) {
    assert.ok(service.exitCode === null && Date.now() < end, `service failed: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  const first = await connect();
  const bytes = frame(ping);
  first.socket.write(bytes.subarray(0, 2));
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(first.replies.length, 0);
  first.socket.write(bytes.subarray(2));
  await first.wait(() => first.replies.length === 1);
  assert.equal(first.replies[0].result.serverApiVersion, version);
  pass("fragmented header/body round trip");
  first.socket.write(Buffer.concat([frame("{broken"), frame(ping)]));
  await first.wait(() => first.replies.length === 3);
  assert.equal(first.replies[1].error.code, -32700);
  assert.equal(first.replies[2].result.serverApiVersion, version);
  pass("malformed JSON receives an error and does not poison the next frame");
  // EOF before a new header is
  // clean, but truncated headers/bodies receive one terminal internal error.
  const truncatedFrames = [
    ['one-byte header', bytes.subarray(0, 1)],
    ['two-byte header', bytes.subarray(0, 2)],
    ['three-byte header', bytes.subarray(0, 3)],
    ['missing body', bytes.subarray(0, 4)],
    ['partial body', bytes.subarray(0, 5)],
  ];
  for (const [label, partial] of truncatedFrames) {
    const peer = await connect();
    peer.socket.end(partial);
    await peer.wait(() => peer.ended());
    assert.deepEqual(peer.replies, [{ id: null, jsonrpc: '2.0', error: { code: -32603, message: 'Internal error' } }]);
    pass(`${label} receives the terminal error before EOF`);
  }
  const cleanEOF = await connect();
  cleanEOF.socket.end();
  await cleanEOF.wait(() => cleanEOF.ended());
  assert.deepEqual(cleanEOF.replies, []);
  const completeEOF = await connect();
  completeEOF.socket.end(frame(ping));
  await completeEOF.wait(() => completeEOF.ended());
  assert.equal(completeEOF.replies.length, 1);
  assert.equal(completeEOF.replies[0].result?.serverApiVersion, version);
  pass('clean EOF and a complete final frame do not add a terminal error');
  const utf32 = (text, littleEndian) => {
    const scalars = Array.from(text, character => character.codePointAt(0));
    const bytes = Buffer.alloc(scalars.length * 4);
    scalars.forEach((scalar, index) => littleEndian
      ? bytes.writeUInt32LE(scalar, index * 4) : bytes.writeUInt32BE(scalar, index * 4));
    return bytes;
  };
  const document = JSON.stringify({ ...ping, note: '👩🏽‍💻 café\u0000' });
  const utf8 = Buffer.from(document);
  const utf16le = Buffer.from(document, 'utf16le');
  const utf16be = Buffer.from(utf16le).swap16();
  const utf32le = utf32(document, true), utf32be = utf32(document, false);
  const encoded = [
    ['UTF-8', utf8], ['UTF-8 BOM', Buffer.concat([Buffer.from([239, 187, 191]), utf8])],
    ['UTF-16LE', utf16le], ['UTF-16LE BOM', Buffer.concat([Buffer.from([255, 254]), utf16le])],
    ['UTF-16BE', utf16be], ['UTF-16BE BOM', Buffer.concat([Buffer.from([254, 255]), utf16be])],
    ['UTF-32LE', utf32le], ['UTF-32BE', utf32be],
    ['UTF-32BE BOM', Buffer.concat([Buffer.from([0, 0, 254, 255]), utf32be])],
  ];
  for (const [label, body] of encoded) {
    const before = first.replies.length, bytes = frame(body);
    first.socket.write(bytes.subarray(0, 5));
    first.socket.write(bytes.subarray(5, 7));
    first.socket.write(bytes.subarray(7));
    await first.wait(() => first.replies.length > before);
    assert.equal(first.replies[before].result?.serverApiVersion, version, label);
    pass(`${label} JSON reaches the real socket dispatcher across partial code units`);
  }
  const rejectedBOM = await connect();
  rejectedBOM.socket.write(Buffer.concat([frame(Buffer.concat([Buffer.from([255, 254, 0, 0]), utf32le])), frame(ping)]));
  await rejectedBOM.wait(() => rejectedBOM.replies.length === 2);
  assert.equal(rejectedBOM.replies[0].error?.code, -32700);
  assert.equal(rejectedBOM.replies[0].id, null);
  assert.equal(rejectedBOM.replies[1].result?.serverApiVersion, version);
  pass('UTF-32LE BOM retains the Foundation decoder rejection');
  for (const [label, bad] of [["oversized header", Buffer.from([1, 0, 128, 0])]]) {
    const peer = await connect();
    peer.socket.write(Buffer.concat([frame(ping), bad]));
    await peer.wait(() => peer.ended());
    assert.equal(peer.replies.length, 2);
    assert.equal(peer.replies[0].result.serverApiVersion, version);
    assert.deepEqual(peer.replies[1], { id: null, jsonrpc: '2.0', error: { code: -32603, message: 'Internal error' } });
    pass(`${label} closes only the invalid connection, preserving earlier valid responses`);
  }
  const checks = [
    [request("ComputerUseIPCAppStartRequest", { app: "" }), -10010],
    [request("ComputerUseIPCAppStartRequest", { app: "   " }), -10010],
    [request("ComputerUseIPCAppStartRequest", { app: "com.apple.Terminal" }, { deadlineUnixMilliseconds: 0 }), -32001],
    [request("ComputerUseIPCListAppsRequest", {}, { deadlineUnixMilliseconds: true }), -32602],
    [request("ComputerUseIPCAppStartRequest", { app: "com.apple.Terminal" }), -10006],
    [request("ComputerUseIPCAppGetAppSnapshotRequest", { app: path.join(temp, "MissingProtocolFixture.app") }), -10010],
    [request("ComputerUseIPCAppGetAppSnapshotRequest", { app: "com.apple.Terminal" }), -10006],
    [request("ComputerUseIPCAppPerformActionRequest", { app: "com.apple.Terminal", action: { type: { _0: "" } } }), -10006],
    [request("ComputerUseIPCAppPerformActionRequest", { app: "com.apple.Terminal", action: { type: {} } }), -32602],
    [request("ComputerUseIPCAppPerformActionRequest", { app: "com.apple.Terminal", action: { setValue: { elementID: "0" } } }), -32602],
    [request("ComputerUseIPCAppPerformActionRequest", { app: "com.apple.Terminal", action: { type: { _0: "x" }, pressKey: { _0: "Return" } } }), -32602],
  ];
  for (const [message, code] of checks) {
    const count = first.replies.length;
    first.socket.write(frame(message));
    await first.wait(() => first.replies.length > count);
    assert.equal(first.replies[count].error.code, code, JSON.stringify(message.params));
  }
  pass("empty targets and invalid/expired deadlines fail before app activation");
  pass("native target policy is enforced without the JavaScript approval layer");
  const typedCorpus = JSON.parse(fs.readFileSync(path.join(root, 'test/typed-app-body-corpus.json'), 'utf8'));
  for (const test of typedCorpus) {
    if (test.expected.outcome === 'decoded') continue;
    let message = JSON.parse(test.input);
    if (test.mode === 'native') {
      // Even a regression in the decoder must hit the forbidden-target gate
      // before any input, app activation or clipboard access can occur.
      if (typeof message.app === 'string') message.app = 'com.apple.Terminal';
      message = request(test.type, message);
    }
    const before = first.replies.length;
    first.socket.write(Buffer.concat([frame(message), frame(ping)]));
    await first.wait(() => first.replies.length === before + 2);
    // Outer expiry precedes typed dispatch; typed failures collapse to the
    // JSON-RPC invalid-params envelope. Native XPC is tested separately.
    assert.equal(first.replies[before].error?.code, message.params.deadlineUnixMilliseconds === 0 ? -32001 : -32602, test.name);
    assert.ok(first.replies[before].error.message.includes(message.params.deadlineUnixMilliseconds === 0 ? 'Request deadline exceeded' : 'Invalid params'), test.name);
    assert.equal(first.replies[before + 1].result?.serverApiVersion, version);
    pass(`typed body rejects before app effects and preserves the connection: ${test.name}`);
  }
  const nullDeadlineBefore = first.replies.length;
  first.socket.write(frame(request('NoSuchOwnedFixtureRequest', {}, { deadlineUnixMilliseconds: null })));
  await first.wait(() => first.replies.length === nullDeadlineBefore + 1);
  assert.equal(first.replies[nullDeadlineBefore].error?.code, -10003);
  pass('null optional deadline does not mask request-type resolution');
  const corpus = JSON.parse(fs.readFileSync(path.join(root, 'test/socket-jsonrpc-corpus.json'), 'utf8'));
  for (const test of corpus) {
    if (test.expected.outcome !== 'error') continue;
    const before = first.replies.length;
    first.socket.write(Buffer.concat([frame(Buffer.from(test.data, 'base64')), frame(ping)]));
    await first.wait(() => first.replies.length === before + 2);
    assert.deepEqual(first.replies[before], { jsonrpc: '2.0', ...test.expected.error }, test.name);
    assert.equal(first.replies[before + 1].result?.serverApiVersion, version);
    pass(`JSON-RPC error and subsequent request: ${test.name}`);
  }
  for (const test of corpus) {
    if (test.expected.kind !== 0) continue;
    const peer = await connect();
    // A coalesced later request must not run after the close acknowledgement.
    peer.socket.write(Buffer.concat([frame(Buffer.from(test.data, 'base64')), frame(ping)]));
    await peer.wait(() => peer.ended());
    assert.deepEqual(peer.replies, [test.expected.response], test.name);
    pass(`close acknowledges its exact ID and stops the connection: ${test.name}`);
  }
  const unknownBefore = first.replies.length;
  first.socket.write(frame({ id: 'owned-string-id', jsonrpc: '2.0', method: 'unknown' }));
  await first.wait(() => first.replies.length === unknownBefore + 1);
  assert.deepEqual(first.replies[unknownBefore], { id: 'owned-string-id', jsonrpc: '2.0', error: { code: -32601, message: 'Method not found' } });
  pass('unknown method returns its error and string ID');
  const maxBytes = 8_388_608;
  const largePing = { ...ping, params: { clientApiVersion: '' } };
  largePing.params.clientApiVersion = 'v'.repeat(maxBytes - Buffer.byteLength(JSON.stringify(largePing)));
  const maximumFrame = frame(largePing);
  assert.equal(maximumFrame.readUInt32LE(), maxBytes);
  const largeBefore = first.replies.length;
  first.socket.write(Buffer.concat([maximumFrame, frame(ping)]));
  await first.wait(() => first.replies.length === largeBefore + 2);
  const dispatchErrors = JSON.parse(fs.readFileSync(path.join(root, 'test/socket-dispatch-error-corpus.json'), 'utf8'));
  const versionError = dispatchErrors.find(test => test.name === "version/'bad'").expected.error;
  assert.deepEqual(first.replies[largeBefore], { id: 1, jsonrpc: '2.0', error: versionError });
  assert.equal(first.replies[largeBefore + 1].result?.serverApiVersion, version);
  pass('inclusive maximum request gets the fixed version error and preserves the connection');
  const malformedByRoute = new Map();
  for (const test of dispatchErrors) {
    if (!test.name.startsWith('outer/') || test.expected.error?.code !== -32602) continue;
    const message = JSON.parse(test.input);
    const params = message.params;
    if (params.clientApiVersion !== version || params.deadlineUnixMilliseconds != null || !Object.hasOwn(params, 'request')) continue;
    if (!malformedByRoute.has(params.requestType)) malformedByRoute.set(params.requestType, { message, expected: test.expected });
  }
  assert.equal(malformedByRoute.size, 40, 'one malformed-body case per request type');
  const unknown = dispatchErrors.find(test => test.name === "unknown/'NoSuchOwnedRequest'").expected.error;
  for (const [route, { message, expected }] of malformedByRoute) {
    const alias = `ComputerUseClient.${route}`;
    const qualified = { ...message, params: { ...message.params, requestType: alias } };
    const index = first.replies.length;
    first.socket.write(Buffer.concat([frame(message), frame(qualified)]));
    await first.wait(() => first.replies.length === index + 2);
    assert.deepEqual(first.replies[index], expected, route);
    assert.deepEqual(first.replies[index + 1], {
      id: message.id, jsonrpc: '2.0', error: { ...unknown, message: unknown.message.replace('NoSuchOwnedRequest', alias) },
    }, alias);
  }
  pass('all 40 route names reach typed validation and module-qualified aliases are rejected');
  // Unknown route names are retained in the mapped error. Foundation
  // escapes their slashes, so a valid maximum input produces an oversized reply.
  const largeUnknown = request('', undefined);
  largeUnknown.params.requestType = '/'.repeat(maxBytes - Buffer.byteLength(JSON.stringify(largeUnknown)));
  const oversizedBefore = first.replies.length;
  first.socket.write(Buffer.concat([frame(largeUnknown), frame(ping)]));
  await first.wait(() => first.replies.length === oversizedBefore + 2);
  assert.deepEqual(first.replies[oversizedBefore], { id: 2, jsonrpc: '2.0', error: { code: -32002, message: 'Response exceeds maximum frame size' } });
  assert.equal(first.replies[oversizedBefore + 1].result?.serverApiVersion, version);
  pass('oversized escaped response is bounded and preserves the connection');
  const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ["--diagnostics"], { encoding: "utf8" }));
  if (diagnostics.screenLocked) {
    const app = path.join(temp, 'InactiveProtocolFixture.app');
    const contents = path.join(app, 'Contents');
    fs.mkdirSync(contents, { recursive: true });
    fs.writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>test.acua.inactive-protocol-fixture</string>
      <key>CFBundleName</key><string>Inactive Protocol Fixture</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      </dict></plist>`);
    for (const message of [request("ComputerUseIPCAppGetAppSnapshotRequest", { app }),
                           request("ComputerUseIPCAppPerformActionRequest", { app, action: { type: { _0: "" } } })]) {
      const count = first.replies.length;
      first.socket.write(frame(message));
      await first.wait(() => first.replies.length > count);
      const error = first.replies[count].error;
      const label = JSON.stringify({ requestType: message.params.requestType, reply: first.replies[count] });
      if (!process.env.CUA_REVIEW_LAUNCHER) {
        assert.equal(error?.code, -10020, label);
      } else if (message.params.requestType === 'ComputerUseIPCAppGetAppSnapshotRequest') {
        // The native launch preparation is reached when auto-unlock is disabled.
        // This bundle deliberately has no executable, so it cannot open or capture.
        assert.equal(error?.code, -10005, label);
        assert.match(error.message, /-10827/, label);
      } else {
        assert.equal(error?.code, -10011, label);
      }
    }
    pass("locked-session requests preserve the selected controller's inactive-target errors");
  }
  for (let i = 0; i < 12; i++) {
    const peer = await connect();
    peer.socket.write(frame(request("ComputerUseIPCListAppsRequest", {})));
    peer.socket.destroy();
  }
  const count = first.replies.length;
  first.socket.write(frame(ping));
  await first.wait(() => first.replies.length > count);
  assert.equal(first.replies[count].result.serverApiVersion, version);
  pass("clients disconnecting during a response do not terminate the server");
  console.log(`ALL PROTOCOL EDGE CHECKS PASSED — artifacts: ${temp}`);
} finally {
  for (const socket of peers) socket.destroy();
  service.kill("SIGTERM");
}
