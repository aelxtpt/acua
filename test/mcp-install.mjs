// Integration test of `AexComputerUseClient mcp install` and `mcp uninstall`
// with the packaged helper, without physical input. Every write goes to a
// temporary directory; the user's own host configurations are checked to stay
// untouched. The written configuration is then used the way an MCP host uses
// it: each entry's command and args are started and must answer initialize
// and tools/list.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const ALL_SERVERS = {
  'computer-use': {name: 'acua', args: ['mcp']},
  'calendar': {name: 'acua-calendar', args: ['calendar', 'mcp']},
  'computer-history': {name: 'acua-computer-history', args: ['computer-history', 'mcp']},
  'event-stream': {name: 'acua-event-stream', args: ['event-stream', 'mcp']},
  'messages': {name: 'acua-messages', args: ['messages', 'mcp']},
};

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bundle = process.env.CUA_REVIEW_BUNDLE || path.join(root, 'service/.build/current/dist/AexComputerUseService.app');
const helper = path.join(bundle, 'Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient');
assert.ok(fs.existsSync(helper), `MCP helper not found: ${helper}`);
const helperPath = fs.realpathSync(helper);

const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'cua-mcp-install-')));
const project = path.join(directory, 'project');
fs.mkdirSync(project);

// The user's real host files: the test must never change them.
const userFiles = [path.join(os.homedir(), '.cursor/mcp.json'), path.join(os.homedir(), '.claude.json')];
const fingerprint = file => fs.existsSync(file) ? fs.statSync(file).mtimeMs : null;
const userFilesBefore = userFiles.map(fingerprint);

function run(args) {
  const result = spawnSync(helper, ['mcp', ...args], {cwd: project, encoding: 'utf8', timeout: 15000});
  return {status: result.status, stdout: result.stdout, stderr: result.stderr};
}

const readServers = file => JSON.parse(fs.readFileSync(file, 'utf8')).mcpServers;

// Starts one configured server like an MCP host and lists its tools.
async function listTools(entry) {
  const server = spawn(entry.command, entry.args, {stdio: ['pipe', 'pipe', 'pipe']});
  let errors = '';
  server.stderr.on('data', chunk => errors += chunk);

  let buffered = '';
  const replies = new Map();
  server.stdout.on('data', chunk => {
    buffered += chunk;
    let newline;
    while ((newline = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (line)
        replies.set(JSON.parse(line).id, JSON.parse(line));
    }
  });

  async function rpc(id, method, params) {
    server.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
    const until = Date.now() + 15000;
    while (!replies.has(id)) {
      assert.ok(Date.now() < until && server.exitCode === null, `${entry.args.join(' ')} ${method} got no reply: ${errors}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    const reply = replies.get(id);
    assert.equal(reply.error, undefined, `${method} failed: ${JSON.stringify(reply.error)}`);
    return reply.result;
  }

  try {
    await rpc(1, 'initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'acua-mcp-install-test', version: '1'}});
    server.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');
    return (await rpc(2, 'tools/list', {})).tools.map(tool => tool.name);
  } finally {
    const exited = new Promise(resolve => server.exitCode !== null ? resolve() : server.once('exit', resolve));
    server.stdin.end();
    server.kill();
    await exited;
  }
}

try {
  // Printing writes nothing and points the host at this very helper.
  const printed = run(['install', '--client', 'cursor']);
  assert.equal(printed.status, 0, printed.stderr);
  assert.deepEqual(JSON.parse(printed.stdout), {mcpServers: {acua: {command: helperPath, args: ['mcp']}}});
  assert.match(printed.stderr, /\.cursor\/mcp\.json/);
  assert.deepEqual(fs.readdirSync(project), []);
  console.log('PASS install --client cursor prints a snippet that starts this helper');

  const claude = run(['install', '--client', 'claude-code', '--server', 'calendar']);
  assert.equal(claude.status, 0, claude.stderr);
  assert.equal(claude.stdout, `claude mcp add --scope user acua-calendar -- ${helperPath} calendar mcp\n`);
  console.log('PASS install --client claude-code prints the claude mcp add command');

  // A host file with a server of its own, edited in place.
  const config = path.join(directory, 'mcp.json');
  fs.writeFileSync(config, JSON.stringify({mcpServers: {other: {command: '/bin/echo', args: []}}, keep: true}));
  const serverFlags = Object.keys(ALL_SERVERS).flatMap(server => ['--server', server]);
  const written = run(['install', '--client', 'generic', '--write', '--config', config, ...serverFlags]);
  assert.equal(written.status, 0, written.stderr);
  const servers = readServers(config);
  assert.deepEqual(Object.keys(servers).sort(), ['other', ...Object.values(ALL_SERVERS).map(server => server.name)].sort());
  for (const {name, args} of Object.values(ALL_SERVERS))
    assert.deepEqual(servers[name], {command: helperPath, args});
  assert.equal(JSON.parse(fs.readFileSync(config, 'utf8')).keep, true);
  console.log('PASS install --write adds every server and keeps the file\'s own entries');

  const again = run(['install', '--client', 'generic', '--write', '--config', config]);
  assert.equal(again.status, 0, again.stderr);
  assert.match(again.stdout, /^acua: unchanged in /);
  console.log('PASS a second install reports the server unchanged');

  // The written entries work as a host would start them.
  for (const {name, args} of Object.values(ALL_SERVERS)) {
    const tools = await listTools({command: servers[name].command, args: servers[name].args});
    assert.ok(tools.length > 0, `${name} listed no tools`);
  }
  assert.ok((await listTools(servers.acua)).includes('get_app_state'));
  console.log('PASS every written entry starts an MCP server that lists its tools');

  const removed = run(['uninstall', '--client', 'generic', '--write', '--config', config, '--server', 'calendar']);
  assert.equal(removed.status, 0, removed.stderr);
  assert.match(removed.stdout, /^acua-calendar: removed in /);
  assert.equal(readServers(config)['acua-calendar'], undefined);
  assert.ok(readServers(config).acua);
  console.log('PASS uninstall --write removes only the named server');

  const projectWrite = run(['install', '--client', 'claude-code', '--write']);
  assert.equal(projectWrite.status, 0, projectWrite.stderr);
  assert.deepEqual(readServers(path.join(project, '.mcp.json')), {acua: {command: helperPath, args: ['mcp']}});
  console.log('PASS install --client claude-code --write writes the project .mcp.json');

  const generic = run(['install', '--client', 'generic', '--write']);
  assert.notEqual(generic.status, 0);
  assert.match(generic.stderr, /--config PATH/);
  console.log('PASS --client generic --write without --config is refused');

  const invalid = path.join(directory, 'invalid.json');
  fs.writeFileSync(invalid, '{"mcpServers": {} // comment\n}');
  const rejected = run(['install', '--client', 'generic', '--write', '--config', invalid]);
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /not valid JSON/);
  assert.equal(fs.readFileSync(invalid, 'utf8'), '{"mcpServers": {} // comment\n}');
  console.log('PASS an invalid configuration is refused and left unchanged');

  const unknown = run(['install', '--client', 'vscode']);
  assert.notEqual(unknown.status, 0);
  console.log('PASS an unknown client is refused');

  assert.deepEqual(userFiles.map(fingerprint), userFilesBefore, 'a user host configuration changed');
  console.log('PASS the user\'s own host configurations were not touched');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
