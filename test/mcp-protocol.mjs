// MCP protocol test of the five packaged servers over stdio, without physical
// input and without a service: every request here is answered by the helper
// itself.
//   - initialize negotiates the protocol version and names each server;
//   - tools/list matches the snapshot of all 31 tool schemas
//     (ACUA_UPDATE_MCP_SNAPSHOT=1 rewrites it after an intended change);
//   - unknown methods, malformed JSON and unknown tools are errors, and the
//     server keeps answering afterwards;
//   - argument errors decided before the service is reached say what is wrong.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {MCPStdioClient, PROTOCOL_VERSION, SERVERS, resultText} from './mcp-stdio-client.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const snapshotPath = path.join(root, 'test/snapshots/mcp-tools.json');
const LATEST_PROTOCOL_VERSION = '2025-11-25';
const JSONRPC_PARSE_ERROR = -32700;
const JSONRPC_METHOD_NOT_FOUND = -32601;

const SERVER_NAMES = {
  'computer-use': 'Computer Use', calendar: 'Calendar', 'computer-history': 'Computer History',
  'event-stream': 'Record & Replay', messages: 'Messages',
};

// Only errors the helper decides on its own. Arguments of tools that act on an
// app are checked after the service's app policy, so they are not here.
const ARGUMENT_ERRORS = [
  ['computer-use', 'get_app_state', {}, /^Missing required argument: app$/],
  ['computer-use', 'get_app_state', {app: 5}, /^Missing required argument: app$/],
  ['computer-use', 'type_text', {}, /^Missing required argument: app$/],
  ['calendar', 'list_events', {}, /^Missing argument: start_date$/],
  ['calendar', 'get_event', {}, /^Missing argument: id$/],
  ['calendar', 'create_event', {title: 5}, /^Invalid argument: title must be a non-empty string$/],
  ['computer-history', 'computer_history_update_settings', {bogus: 1}, /^Invalid Computer History settings: /],
];

const UNKNOWN_TOOL_TEXT = {
  calendar: /^\[-32602\] Invalid params: Unknown tool: no_such_tool$/,
};

function describeServer(initialized, tools) {
  return {
    serverInfo: initialized.serverInfo,
    capabilities: initialized.capabilities,
    instructions: initialized.instructions ?? null,
    tools,
  };
}

const observed = {};
const clients = [];
try {
  for (const [server, args] of Object.entries(SERVERS)) {
    const client = new MCPStdioClient(args);
    clients.push(client);

    const initialized = await client.initialize();
    assert.equal(initialized.protocolVersion, PROTOCOL_VERSION, `${server} keeps the requested protocol version`);
    assert.equal(initialized.serverInfo.name, SERVER_NAMES[server]);
    assert.ok(initialized.capabilities.tools, `${server} declares tools`);

    const {tools} = await client.request('tools/list', {});
    assert.equal(new Set(tools.map(tool => tool.name)).size, tools.length, `${server} lists each tool once`);
    for (const tool of tools)
      assert.equal(tool.inputSchema?.type, 'object', `${server} ${tool.name} takes an object`);
    observed[server] = describeServer(initialized, tools);

    assert.deepEqual(await client.request('ping', {}), {});

    const unknownMethod = await client.response(client.start('resources/list', {}));
    assert.equal(unknownMethod.error?.code, JSONRPC_METHOD_NOT_FOUND, JSON.stringify(unknownMethod));

    const unknownTool = await client.callTool('no_such_tool');
    assert.equal(unknownTool.isError, true);
    assert.match(resultText(unknownTool), UNKNOWN_TOOL_TEXT[server] ?? /^Unknown tool: no_such_tool$/);

    // The SDK answers with a random id rather than null; only the code is the contract.
    client.writeLine('{"jsonrpc":"2.0","id":99,"method":');
    const parseError = await client.waitFor(message => message.error?.code === JSONRPC_PARSE_ERROR, 5000);
    assert.ok(parseError, `${server} reports malformed JSON`);
    assert.deepEqual(await client.request('ping', {}), {}, `${server} keeps answering after malformed JSON`);
  }
  console.log('PASS each server initializes, names itself and declares tools');
  console.log('PASS unknown methods, unknown tools and malformed JSON are errors, and the servers keep answering');

  const toolCount = Object.values(observed).reduce((count, server) => count + server.tools.length, 0);
  assert.equal(toolCount, 31, 'thirty computer-use tools plus end_turn');

  if (process.env.ACUA_UPDATE_MCP_SNAPSHOT === '1') {
    fs.mkdirSync(path.dirname(snapshotPath), {recursive: true});
    fs.writeFileSync(snapshotPath, JSON.stringify(observed, null, 2) + '\n');
    console.log(`WROTE ${snapshotPath}`);
  }
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
  for (const server of Object.keys(SERVERS))
    assert.deepEqual(observed[server], snapshot[server],
      `${server} differs from test/snapshots/mcp-tools.json; rerun with ACUA_UPDATE_MCP_SNAPSHOT=1 if the change is intended`);
  console.log('PASS tools/list of all five servers matches the 31-tool snapshot');

  // Version negotiation on a fresh connection.
  const legacy = new MCPStdioClient(SERVERS.calendar);
  clients.push(legacy);
  assert.equal((await legacy.initialize({}, '2024-11-05')).protocolVersion, '2024-11-05');
  const again = await legacy.response(legacy.start('initialize', {protocolVersion: PROTOCOL_VERSION, capabilities: {},
    clientInfo: {name: 'acua-mcp-test-client', version: '1'}}));
  assert.ok(again.error, 'a second initialize is refused');

  const future = new MCPStdioClient(SERVERS['computer-history']);
  clients.push(future);
  assert.equal((await future.initialize({}, '1999-01-01')).protocolVersion, LATEST_PROTOCOL_VERSION,
    'an unsupported version gets the latest the server supports');
  console.log('PASS initialize keeps a supported older version, offers the latest for an unknown one and runs once');

  const byServer = {};
  for (const [server, tool, args, expected] of ARGUMENT_ERRORS) {
    byServer[server] ??= await (async () => {
      const client = new MCPStdioClient(SERVERS[server]);
      clients.push(client);
      await client.initialize();
      return client;
    })();

    const result = await byServer[server].callTool(tool, args);
    assert.equal(result.isError, true, `${tool} ${JSON.stringify(args)} is an error`);
    assert.match(resultText(result), expected, `${tool} ${JSON.stringify(args)}`);
  }
  console.log('PASS invalid arguments are tool errors that name the argument');
} finally {
  for (const client of clients)
    client.close();
}
