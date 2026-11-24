// Integration test of `hooks install` and `turn-ended --agent-process` with the
// packaged client, without physical input. This test process plays the agent:
//   - hooks install --write edits only the file it is given, and is idempotent;
//     hooks uninstall removes exactly what install added;
//   - the MCP helper started by this process and the Stop hook command run by
//     this process through /bin/sh, as Claude Code runs it, name one session;
//   - the Codex notify still runs the notify it replaced;
//   - nothing is written to the user's own agent files.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bundle = process.env.CUA_REVIEW_BUNDLE || path.join(root, 'service/.build/current/dist/AexComputerUseService.app');
const helper = path.join(bundle, 'Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient');
assert.ok(fs.existsSync(helper), `client not found: ${helper}`);
const executable = fs.realpathSync(helper);

const userFiles = ['.claude/settings.json', '.cursor/hooks.json', '.codex/config.toml'].map(file => path.join(os.homedir(), file));
const digest = file => fs.existsSync(file) ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') : 'absent';
const userDigests = userFiles.map(digest);

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'acua-hooks-'));
const codexHome = path.join(directory, 'codex');
const files = {
  'claude-code': path.join(directory, 'claude/settings.json'),
  cursor: path.join(directory, 'cursor/hooks.json'),
  codex: path.join(codexHome, 'config.toml'),
};

function client(args, options = {}) {
  const result = spawnSync(helper, args, {encoding: 'utf8', env: {...process.env, CODEX_HOME: codexHome}, ...options});
  assert.equal(result.status, 0, `${args.join(' ')} failed: ${result.stderr}`);
  return result;
}

const install = (agent, ...extra) => client(['hooks', 'install', '--client', agent, '--write', '--config', files[agent], ...extra]);
const uninstall = agent => client(['hooks', 'uninstall', '--client', agent, '--write', '--config', files[agent]]);
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const claudeStopCommands = () => (json(files['claude-code']).hooks?.Stop ?? []).flatMap(group => group.hooks.map(hook => hook.command));
const cursorStopCommands = () => (json(files.cursor).hooks?.stop ?? []).map(hook => hook.command);

function runHook(command, stdin) {
  // Claude Code runs a command hook through /bin/sh, with the event as JSON on stdin.
  const result = spawnSync('/bin/sh', ['-c', command], {encoding: 'utf8', input: stdin});
  assert.equal(result.status, 0, `hook failed: ${result.stderr}`);
  assert.equal(result.stdout, '', 'a stop hook writes nothing to stdout (Cursor reads it as JSON)');
  return result.stderr;
}

async function helperSession() {
  const mcp = spawn(helper, ['mcp'], {stdio: ['pipe', 'pipe', 'pipe']});
  let buffered = '';
  const replies = new Map();
  mcp.stdout.on('data', chunk => {
    buffered += chunk;
    let newline;
    while ((newline = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (line) {
        const message = JSON.parse(line);
        if (message.id !== undefined)
          replies.set(message.id, message);
      }
    }
  });

  let id = 0;
  const rpc = async (method, params) => {
    const requestID = ++id;
    mcp.stdin.write(JSON.stringify({jsonrpc: '2.0', id: requestID, method, params}) + '\n');
    const until = Date.now() + 15000;
    while (!replies.has(requestID)) {
      assert.ok(Date.now() < until && mcp.exitCode === null, `${method} got no reply`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    return replies.get(requestID).result;
  };

  try {
    await rpc('initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'acua-hooks-test', version: '1'}});
    mcp.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');
    const ended = await rpc('tools/call', {name: 'end_turn', arguments: {}});
    const text = ended.content.map(item => item.text).join('\n');
    const match = text.match(/^Ended session (acua-agent-\d+-\d+\.\d{6})\./);
    assert.ok(match, `end_turn names an agent-process session: ${text}`);
    return match[1];
  } finally {
    mcp.stdin.end();
    mcp.kill('SIGTERM');
  }
}

try {
  // Printing writes nothing.
  const printed = client(['hooks', 'install', '--client', 'claude-code']);
  assert.ok(JSON.parse(printed.stdout).hooks.Stop[0].hooks[0].command.includes('turn-ended --agent-process'));
  assert.ok(!fs.existsSync(files['claude-code']));
  console.log('PASS hooks install without --write prints the hook and writes nothing');

  // Claude Code, beside a hook of the user's.
  fs.mkdirSync(path.dirname(files['claude-code']), {recursive: true});
  fs.writeFileSync(files['claude-code'], JSON.stringify({model: 'opus', hooks: {Stop: [{hooks: [{type: 'command', command: 'true'}]}]}}));
  assert.match(install('claude-code').stdout, /Stop hook: added in /);
  const [userHook, claudeHook] = claudeStopCommands();
  assert.equal(userHook, 'true');
  // The path is single-quoted only when it needs it (the installed one has a space).
  assert.ok(claudeHook.endsWith(' turn-ended --agent-process'), claudeHook);
  assert.equal(claudeHook.slice(0, -' turn-ended --agent-process'.length).replace(/^'(.*)'$/, '$1'), executable);
  assert.equal(json(files['claude-code']).model, 'opus');
  assert.match(install('claude-code').stdout, /Stop hook: unchanged in /);
  assert.equal(claudeStopCommands().length, 2);
  console.log('PASS claude-code Stop hook is added beside the user\'s, once');

  // The hook and the MCP helper this process started name the same session.
  const session = await helperSession();
  assert.ok(session.startsWith(`acua-agent-${process.pid}-`), `the helper's session is this process's: ${session}`);
  const claudeReport = runHook(claudeHook, JSON.stringify({session_id: 'claude-session', hook_event_name: 'Stop'}));
  assert.ok(claudeReport.includes(session), `the Stop hook ends the helper's session: ${claudeReport}`);
  console.log('PASS the Stop hook run through /bin/sh ends the session of the MCP helper this agent started');

  // Cursor.
  assert.match(install('cursor').stdout, /stop hook: added in /);
  assert.equal(json(files.cursor).version, 1);
  const [cursorHook] = cursorStopCommands();
  const cursorReport = runHook(cursorHook, JSON.stringify({conversation_id: 'c', status: 'completed', loop_count: 0}));
  assert.ok(cursorReport.includes(session), cursorReport);
  console.log('PASS cursor stop hook is written to a version 1 hooks.json and ends the same session');

  // Codex: an existing notify keeps running.
  const marker = path.join(directory, 'previous-notify.json');
  fs.mkdirSync(codexHome, {recursive: true});
  fs.writeFileSync(files.codex, `notify = ["/bin/sh", "-c", "printf %s \\"$1\\" > ${marker}", "sh"]\nmodel = "gpt-5"\n`);
  assert.match(install('codex').stdout, /notify: updated in /);
  const notifyLine = fs.readFileSync(files.codex, 'utf8').split('\n')[0];
  const notify = JSON.parse(notifyLine.replace(/^notify = /, ''));
  assert.deepEqual(notify.slice(0, 3), [executable, 'turn-ended', '--previous-notify']);
  const payload = JSON.stringify({type: 'agent-turn-complete', 'thread-id': 'thread', 'turn-id': 'turn'});
  const notified = spawnSync(notify[0], [...notify.slice(1), payload], {encoding: 'utf8'});
  assert.equal(notified.status, 0, notified.stderr);
  const until = Date.now() + 5000;
  while (!fs.existsSync(marker) && Date.now() < until)
    await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(fs.readFileSync(marker, 'utf8'), payload, 'the replaced notify receives the same payload');
  console.log('PASS codex notify ends the turn and still runs the notify it replaced');

  // Uninstall removes only what install added.
  assert.match(uninstall('claude-code').stdout, /Stop hook: removed in /);
  assert.deepEqual(claudeStopCommands(), ['true']);
  assert.match(uninstall('cursor').stdout, /stop hook: removed in /);
  assert.deepEqual(cursorStopCommands(), []);
  assert.match(uninstall('codex').stdout, /notify: removed in /);
  assert.equal(fs.readFileSync(files.codex, 'utf8'), `notify = ["/bin/sh", "-c", "printf %s \\"$1\\" > ${marker}", "sh"]\nmodel = "gpt-5"\n`);
  assert.match(uninstall('cursor').stdout, /stop hook: not present in /);
  console.log('PASS hooks uninstall removes only the hooks install added and restores the previous notify');

  const bothForms = spawnSync(helper, ['turn-ended', '--agent-process', payload], {encoding: 'utf8'});
  assert.notEqual(bothForms.status, 0, 'a notification and --agent-process together are rejected');
  console.log('PASS turn-ended rejects a notification together with --agent-process');

  assert.deepEqual(userFiles.map(digest), userDigests, 'the user\'s own agent files are untouched');
  console.log('PASS the user\'s own Claude Code, Cursor and Codex files are untouched');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
