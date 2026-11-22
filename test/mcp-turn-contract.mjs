// Integration test of the packaged MCP helper over stdio, as any MCP host
// starts it: `AexComputerUseClient mcp`. It checks the public turn contract at
// the MCP layer without physical input:
//   - tools/list keeps the ten automation tools and adds end_turn;
//   - malformed _meta.x-acua-turn and end_turn arguments are rejected;
//   - end_turn without arguments ends this connection's implicit session and
//     never launches the service.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const AUTOMATION_TOOLS = ['list_apps', 'get_app_state', 'click', 'perform_secondary_action', 'set_value',
  'select_text', 'scroll', 'drag', 'press_key', 'type_text'];
// Matched against the full command line: process names are cut to 16 bytes.
const SERVICE_EXECUTABLE = 'AexComputerUseService.app/Contents/MacOS/AexComputerUseService';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bundle = process.env.CUA_REVIEW_BUNDLE || path.join(root, 'service/.build/current/dist/AexComputerUseService.app');
const helper = path.join(bundle, 'Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient');
assert.ok(fs.existsSync(helper), `MCP helper not found: ${helper}`);

function serviceRunning() {
  // pgrep exits 1 when nothing matches.
  return spawnSync('/usr/bin/pgrep', ['-f', SERVICE_EXECUTABLE]).status === 0;
}

const serviceWasRunning = serviceRunning();
const client = spawn(helper, ['mcp'], {stdio: ['pipe', 'pipe', 'pipe']});
let errors = '';
client.stderr.on('data', chunk => errors += chunk);

let buffered = '';
const replies = new Map();
client.stdout.on('data', chunk => {
  buffered += chunk;
  let newline;
  while ((newline = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, newline).trim();
    buffered = buffered.slice(newline + 1);
    if (!line)
      continue;

    const message = JSON.parse(line);
    if (message.id !== undefined)
      replies.set(message.id, message);
  }
});

let id = 0;
async function rpc(method, params) {
  const requestID = ++id;
  client.stdin.write(JSON.stringify({jsonrpc: '2.0', id: requestID, method, params}) + '\n');

  const until = Date.now() + 15000;
  while (!replies.has(requestID)) {
    assert.ok(Date.now() < until && client.exitCode === null, `${method} got no reply: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }

  const reply = replies.get(requestID);
  replies.delete(requestID);
  assert.equal(reply.error, undefined, `${method} failed: ${JSON.stringify(reply.error)}`);
  return reply.result;
}

const callTool = (name, args, meta) => rpc('tools/call', {name, arguments: args, ...(meta ? {_meta: meta} : {})});
const text = result => result.content.map(item => item.text).join('\n');

try {
  const initialized = await rpc('initialize', {protocolVersion: '2025-06-18', capabilities: {},
    clientInfo: {name: 'acua-turn-contract-test', version: '1'}});
  assert.equal(initialized.serverInfo.name, 'Computer Use');
  client.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');

  const tools = (await rpc('tools/list', {})).tools;
  assert.deepEqual(tools.map(tool => tool.name), [...AUTOMATION_TOOLS, 'end_turn']);
  const endTurn = tools.find(tool => tool.name === 'end_turn');
  assert.deepEqual(Object.keys(endTurn.inputSchema.properties).sort(), ['session_id', 'turn_id']);
  assert.equal(endTurn.inputSchema.additionalProperties, false);
  console.log('PASS tools/list keeps the automation tools and adds end_turn');

  const notAnObject = await callTool('end_turn', {}, {'x-acua-turn': '{"session_id":"s"}'});
  assert.equal(notAnObject.isError, true);
  assert.match(text(notAnObject), /Invalid _meta\.x-acua-turn: expected an object/);

  const wrongType = await callTool('list_apps', {}, {'x-acua-turn': {turn_id: 7}});
  assert.equal(wrongType.isError, true, 'every tool rejects a malformed x-acua-turn, not only end_turn');
  assert.match(text(wrongType), /Invalid _meta\.x-acua-turn/);
  console.log('PASS a malformed _meta.x-acua-turn is rejected');

  const numericTurn = await callTool('end_turn', {turn_id: 5});
  assert.equal(numericTurn.isError, true);
  assert.match(text(numericTurn), /Invalid end_turn argument turn_id: expected a string/);

  const emptySession = await callTool('end_turn', {session_id: ''});
  assert.equal(emptySession.isError, true);
  assert.match(text(emptySession), /Invalid end_turn argument session_id: expected a non-empty string/);
  console.log('PASS invalid end_turn arguments are rejected');

  const ended = await callTool('end_turn', {});
  assert.equal(ended.isError, false, text(ended));
  assert.match(text(ended), /^Ended session acua-mcp-[0-9A-F-]{36}\./);
  if (!serviceWasRunning)
    assert.match(text(ended), /was not running, so nothing was stopped/);
  assert.equal(serviceRunning(), serviceWasRunning, 'end_turn never launches the service');
  console.log('PASS end_turn ends the implicit session without launching the service');

  const named = await callTool('end_turn', {}, {'x-acua-turn': {session_id: 'agent', turn_id: 't1'}});
  assert.equal(named.isError, false, text(named));
  assert.match(text(named), /^Ended turn t1 of session agent\./);
  console.log('PASS end_turn without arguments ends the turn named in _meta');
} finally {
  client.stdin.end();
  client.kill('SIGTERM');
}
