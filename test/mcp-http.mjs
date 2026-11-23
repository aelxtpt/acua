// Integration test of MCP over streamable HTTP with the packaged helper
// (`mcp --http 0`), without physical input and without a service:
//   - it listens on 127.0.0.1 only, and prints its URL and a new token;
//   - a request without the token, with a wrong one, on another path or from
//     a foreign Origin is refused before any MCP session exists;
//   - initialize opens a session (Mcp-Session-Id); tools/list and end_turn
//     work in it, over SSE responses;
//   - two sessions are independent, each with its own turn session;
//   - DELETE ends a session, and an unknown session is 404;
//   - SIGTERM stops the server.
import assert from 'node:assert/strict';
import net from 'node:net';
import os from 'node:os';
import {spawn} from 'node:child_process';
import {PROTOCOL_VERSION, packagedHelper} from './mcp-stdio-client.mjs';

const AUTOMATION_TOOLS = ['list_apps', 'get_app_state', 'click', 'perform_secondary_action', 'set_value',
  'select_text', 'scroll', 'drag', 'press_key', 'type_text', 'end_turn'];

const server = spawn(packagedHelper(), ['mcp', '--http', '0'], {stdio: ['ignore', 'ignore', 'pipe']});
let announcement = '';
server.stderr.on('data', chunk => announcement += chunk);

async function announced() {
  const until = Date.now() + 15000;
  for (;;) {
    const url = announcement.match(/MCP over HTTP: (http:\/\/127\.0\.0\.1:(\d+)\/mcp)/);
    const token = announcement.match(/^Token: ([0-9a-f]{64})$/m);
    if (url && token)
      return {url: url[1], port: Number(url[2]), token: token[1]};

    assert.ok(Date.now() < until && server.exitCode === null, `the server never announced itself: ${announcement}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

/// The JSON-RPC messages of an SSE or JSON response body.
function messages(contentType, body) {
  // Refusals from the gate are plain text.
  if (contentType?.startsWith('application/json'))
    return body ? [JSON.parse(body)] : [];
  if (!contentType?.startsWith('text/event-stream'))
    return [];

  return body.split('\n\n')
    .map(event => event.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n'))
    .filter(data => data)
    .map(data => JSON.parse(data));
}

try {
  const {url, port, token} = await announced();
  console.log('PASS the server announces a loopback URL and a 256-bit token');

  const headers = (extra = {}) => ({
    'Content-Type': 'application/json', Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`, ...extra,
  });
  let nextID = 0;
  async function post(message, extra = {}, target = url) {
    const response = await fetch(target, {method: 'POST', headers: headers(extra), body: JSON.stringify(message)});
    return {status: response.status, headers: response.headers,
            messages: messages(response.headers.get('content-type'), await response.text())};
  }
  const initialize = () => post({jsonrpc: '2.0', id: ++nextID, method: 'initialize',
    params: {protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: {name: 'acua-http-test', version: '1'}}});

  // Refused before any session exists.
  assert.equal((await post({jsonrpc: '2.0', id: 1, method: 'ping'}, {Authorization: ''})).status, 401);
  const wrong = await fetch(url, {method: 'POST', headers: headers({Authorization: `Bearer ${'0'.repeat(64)}`}), body: '{}'});
  assert.equal(wrong.status, 401);
  assert.equal(wrong.headers.get('www-authenticate'), 'Bearer');
  assert.equal((await post({jsonrpc: '2.0', id: 1, method: 'ping'}, {}, url.replace('/mcp', '/other'))).status, 404);
  console.log('PASS requests without the right token, or on another path, are refused');

  assert.equal((await post({jsonrpc: '2.0', id: ++nextID, method: 'initialize',
    params: {protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: {name: 'x', version: '1'}}},
    {Origin: 'http://evil.example'})).status, 403);
  console.log('PASS a request from a foreign Origin is refused');

  // A session.
  const opened = await initialize();
  assert.equal(opened.status, 200);
  const session = opened.headers.get('mcp-session-id');
  assert.ok(session, 'initialize returns Mcp-Session-Id');
  const initialized = opened.messages.find(message => message.result);
  assert.equal(initialized.result.serverInfo.name, 'Computer Use');
  assert.equal(initialized.result.protocolVersion, PROTOCOL_VERSION);
  const inSession = {'Mcp-Session-Id': session, 'Mcp-Protocol-Version': PROTOCOL_VERSION};
  assert.equal((await post({jsonrpc: '2.0', method: 'notifications/initialized'}, inSession)).status, 202);

  const listed = await post({jsonrpc: '2.0', id: ++nextID, method: 'tools/list', params: {}}, inSession);
  assert.deepEqual(listed.messages.find(message => message.id === nextID).result.tools.map(tool => tool.name), AUTOMATION_TOOLS);
  console.log('PASS initialize opens a session, and tools/list answers in it over SSE');

  const endTurn = async sessionHeaders => {
    const reply = await post({jsonrpc: '2.0', id: ++nextID, method: 'tools/call', params: {name: 'end_turn', arguments: {}}}, sessionHeaders);
    const text = reply.messages.find(message => message.id === nextID).result.content[0].text;
    return text.match(/^Ended session (acua-http-[0-9A-F-]{36})\./)?.[1];
  };
  const firstTurnSession = await endTurn(inSession);
  assert.ok(firstTurnSession, 'end_turn ends this HTTP session\'s own turn session');

  const second = await initialize();
  const secondSession = second.headers.get('mcp-session-id');
  assert.ok(secondSession && secondSession !== session);
  const secondHeaders = {'Mcp-Session-Id': secondSession, 'Mcp-Protocol-Version': PROTOCOL_VERSION};
  await post({jsonrpc: '2.0', method: 'notifications/initialized'}, secondHeaders);
  const secondTurnSession = await endTurn(secondHeaders);
  assert.ok(secondTurnSession && secondTurnSession !== firstTurnSession, 'each HTTP session is its own turn session');
  assert.equal(await endTurn(inSession), firstTurnSession, 'a session keeps its turn session');
  console.log('PASS two HTTP sessions are independent, each with its own turn session');

  // Session errors and the end of a session.
  assert.equal((await post({jsonrpc: '2.0', id: ++nextID, method: 'ping'}, {'Mcp-Protocol-Version': PROTOCOL_VERSION})).status, 400,
    'a request outside initialize needs a session');
  assert.equal((await post({jsonrpc: '2.0', id: ++nextID, method: 'ping'}, {'Mcp-Session-Id': 'no-such-session'})).status, 404);
  const deleted = await fetch(url, {method: 'DELETE', headers: headers(inSession)});
  assert.equal(deleted.status, 200);
  assert.equal((await post({jsonrpc: '2.0', id: ++nextID, method: 'ping'}, inSession)).status, 404, 'a deleted session is gone');
  const stillOpen = await post({jsonrpc: '2.0', id: ++nextID, method: 'ping'}, secondHeaders);
  assert.deepEqual(stillOpen.messages.find(message => message.id === nextID)?.result, {}, 'the other session still answers');
  console.log('PASS a request needs a session, an unknown or deleted session is 404, and other sessions stay');

  // Loopback only: another address of this machine does not accept.
  const external = Object.values(os.networkInterfaces()).flat().find(address => address.family === 'IPv4' && !address.internal);
  if (external) {
    const refused = await new Promise(resolve => {
      const socket = net.createConnection({host: external.address, port}, () => { socket.destroy(); resolve(false); });
      socket.once('error', () => resolve(true));
      socket.setTimeout(3000, () => { socket.destroy(); resolve(true); });
    });
    assert.ok(refused, `the server accepted a connection on ${external.address}`);
    console.log('PASS the server accepts connections on 127.0.0.1 only');
  } else {
    console.log('SKIP no non-loopback IPv4 address to check that the server is loopback only');
  }

  server.kill('SIGTERM');
  const exited = await new Promise(resolve => {
    server.once('exit', () => resolve(true));
    setTimeout(() => resolve(false), 5000);
  });
  assert.ok(exited, 'SIGTERM stops the server');
  console.log('PASS SIGTERM stops the server');
} finally {
  if (server.exitCode === null)
    server.kill('SIGKILL');
}
