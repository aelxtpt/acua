// Integration test of the public turn contract against the real service, over
// the socket wire that the Rust library uses (Client::turn_ended).
//
// A user stop holds until the turn that used the app ends. Ending a different
// turn of the same session must not lift it; ending the right turn, or the
// whole session, must. Requests that still carry an ended turn are refused.
//
// Needs the Accessibility grant (AppStart reads the fixture's window), so it
// runs with the physical batches; it never moves the pointer or types.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {serviceTestEnvironment, serviceTestExecutable} from './service-test-environment.mjs';

const USER_STOPPED_SESSION = -10012;
const TURN_ENDED = -10021;
const FIXTURE_BUNDLE = 'com.aex.computeruse.turn-fixture';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ['--diagnostics'], {encoding: 'utf8'}));
assert.ok(!diagnostics.screenLocked && diagnostics.accessibility, 'the turn contract test requires an unlocked desktop with the Accessibility grant');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-turn-'));
const app = path.join(directory, 'TurnFixture.app');
const binary = path.join(app, 'Contents/MacOS/TurnFixture');
fs.mkdirSync(path.dirname(binary), {recursive: true});
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${FIXTURE_BUNDLE}</string><key>CFBundleExecutable</key><string>TurnFixture</string>
<key>CFBundleName</key><string>TurnFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/InputFixture.swift'), '-o', binary], {stdio: 'inherit'});
execFileSync('codesign', ['--force', '--sign', '-', app], {stdio: 'inherit'});

const endpoint = path.join(directory, 'service.sock');
const fixture = spawn(binary, [directory], {stdio: ['ignore', 'ignore', 'inherit']});
const service = spawn(serviceTestExecutable(root), [endpoint], {
  env: serviceTestEnvironment({ACUA_HOME: path.join(directory, 'acua'), CODEX_HOME: path.join(directory, 'codex')}),
  stdio: ['ignore', 'ignore', 'pipe'],
});
let errors = '';
service.stderr.on('data', chunk => errors += chunk);

let socket;
try {
  const events = path.join(directory, 'events.jsonl');
  const deadline = Date.now() + 10000;
  while (!(fs.existsSync(endpoint) && fs.existsSync(events) && fs.readFileSync(events, 'utf8').includes('"ready"'))) {
    assert.ok(Date.now() < deadline, `service or fixture did not start: ${errors}`);
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
  async function request(requestType, body, turn) {
    const params = {clientApiVersion: 'AcuaComputerUseIPC-5', requestType, request: body};
    if (turn)
      params.agentTurnMetadata = turn;

    const message = Buffer.from(JSON.stringify({id: ++id, jsonrpc: '2.0', method: 'request', params}));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(message.length);
    socket.write(Buffer.concat([header, message]));

    const until = Date.now() + 15000;
    while (!replies.length) {
      assert.ok(Date.now() < until, `${requestType} timed out: ${errors}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    return replies.shift();
  }

  // The full path, because the disposable bundle is not in Launch Services.
  // A stop marks its identifier exactly as given, while sessions are keyed by
  // Foundation's canonical path (/tmp, not /private/tmp). The first start
  // reports that path, so every later request uses the service's own form.
  let target = app;
  const start = turn => request('ComputerUseIPCAppStartRequest', {app: target}, turn);
  const stop = turn => request('ComputerUseIPCAppStopRequest', {app: target}, turn);
  const endTurn = (session, turn) =>
    request('ComputerUseIPCTurnEndedRequest', turn ? {threadID: session, turnID: turn} : {threadID: session});
  const errorCode = reply => reply.error?.code;

  // "ready" is written before the running fixture is visible to the service's
  // app lookup, which is what AppStart resolves the bundle identifier with.
  const listed = Date.now() + 10000;
  for (;;) {
    const apps = (await request('ComputerUseIPCListAppsRequest', {})).result ?? [];
    if (apps.some(app => app.bundleIdentifier === FIXTURE_BUNDLE))
      break;

    assert.ok(Date.now() < listed, `the fixture never appeared in the app list: ${JSON.stringify(apps)}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }

  // The disposable bundle is not registered with Launch Services; a policy
  // request by path makes it known to the service, as in the Rust probe.
  const policy = await request('ComputerUseIPCAppPolicyRequest', {app});
  assert.equal(policy.result?.target?.bundleIdentifier, FIXTURE_BUNDLE, JSON.stringify(policy));

  // Named session and turns, as sent by x-acua-turn.
  const first = {session_id: 'agent-session', turn_id: 'turn-1'};
  const second = {session_id: 'agent-session', turn_id: 'turn-2'};

  const firstStart = await start(first);
  assert.equal(errorCode(firstStart), undefined, `the first turn starts the app: ${JSON.stringify(firstStart.error)}`);
  target = firstStart.result.currentApp.appPath.replace(/\/+$/, '');
  assert.equal(errorCode(await stop(first)), undefined, 'a stop is accepted');
  assert.equal(errorCode(await start(first)), USER_STOPPED_SESSION, 'the stop holds within the turn');
  console.log('PASS a user stop holds within the turn');

  assert.deepEqual((await endTurn('agent-session', 'turn-other')).result, {}, 'ending another turn is acknowledged');
  assert.equal(errorCode(await start(second)), USER_STOPPED_SESSION, 'ending a different turn keeps the stop');
  console.log('PASS ending a different turn keeps the stop');

  assert.deepEqual((await endTurn('agent-session', 'turn-1')).result, {});
  assert.equal(errorCode(await start(second)), undefined, 'ending the turn that used the app lifts the stop');
  console.log('PASS ending the matching turn lifts the stop');

  assert.equal(errorCode(await start(first)), TURN_ENDED, 'a request from the ended turn is refused');
  console.log('PASS a request carrying an ended turn is refused');

  // An app used by two sessions stays stopped until both have ended, so the
  // named session ends completely before the implicit one starts.
  assert.deepEqual((await endTurn('agent-session')).result, {});

  // An implicit per-connection session, as the MCP helper sends without _meta.
  const implicit = {session_id: 'acua-mcp-connection'};
  assert.equal(errorCode(await start(implicit)), undefined);
  assert.equal(errorCode(await stop(implicit)), undefined);
  assert.equal(errorCode(await start(implicit)), USER_STOPPED_SESSION);
  assert.deepEqual((await endTurn('acua-mcp-connection')).result, {});
  assert.equal(errorCode(await start(implicit)), undefined, 'ending the implicit session lifts the stop');
  console.log('PASS ending an implicit session lifts the stop');
} finally {
  socket?.destroy();
  for (const child of [service, fixture])
    child.kill('SIGTERM');
}
console.log('Turn contract artifacts:', directory);
