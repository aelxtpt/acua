// End-to-end test with Claude Code as the MCP host: `claude -p` starts the
// packaged helper over stdio, uses a disposable app through the ACUA tools,
// and ends its turn through the Stop hook that `hooks install` prints.
//   - the agent types into the app's text field and presses its button,
//     checked from the app's own event log, not from the agent's answer;
//   - the Stop hook ends the session of the helper that this Claude Code
//     process started (the agent-process session);
//   - the app is pre-approved through [apps].allow in a temporary ACUA_HOME,
//     so no approval dialog opens.
// It types and clicks for real, runs one short prompt on the logged-in
// account, and runs with the physical groups. CLAUDE_E2E_CLAUDE selects the
// claude executable (default: claude on PATH).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {packagedHelper} from './mcp-stdio-client.mjs';
import {uniqueFixtureBundle, fixtureAppTarget} from './service-test-environment.mjs';

const TEXT = 'hello from claude';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const claude = process.env.CLAUDE_E2E_CLAUDE || 'claude';
const helper = packagedHelper();
const serviceExecutable = fs.realpathSync(helper)
  .replace(/\/Contents\/SharedSupport\/AexComputerUseClient\.app\/Contents\/MacOS\/AexComputerUseClient$/,
           '/Contents/MacOS/AexComputerUseService');
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

// A nested Claude Code must not inherit the session of the one running this
// test (its socket, entrypoint or session ids).
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^CLAUDE/.test(key)));

const status = spawnSync(claude, ['auth', 'status'], {encoding: 'utf8', env: environment});
assert.equal(status.error, undefined, `could not run ${claude}: ${status.error}`);
assert.ok(JSON.parse(status.stdout || '{}').loggedIn, `${claude} is not logged in; run \`${claude} auth login\` first`);

const servicePIDs = () => new Set(spawnSync('/usr/bin/pgrep', ['-f', serviceExecutable], {encoding: 'utf8'})
  .stdout.split('\n').filter(Boolean).map(Number));
const runningBefore = servicePIDs();
// The helper must launch the service itself: one already running read another
// ACUA_HOME, so the fixture would not be pre-approved.
assert.equal(runningBefore.size, 0, `quit the running service first (pids ${[...runningBefore]}): ${serviceExecutable}`);

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'acua-claude-e2e-'));
const bundleIdentifier = uniqueFixtureBundle('com.aex.computeruse.claude-e2e-fixture');
const app = path.join(directory, 'ClaudeE2EFixture.app');
const binary = path.join(app, 'Contents/MacOS/ClaudeE2EFixture');
fs.mkdirSync(path.dirname(binary), {recursive: true});
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string><key>CFBundleExecutable</key><string>ClaudeE2EFixture</string>
<key>CFBundleName</key><string>ClaudeE2EFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('swiftc', ['-O', '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/ClaudeCodeFixture.swift'), '-o', binary], {stdio: 'inherit'});
execFileSync('codesign', ['--force', '--sign', '-', app], {stdio: 'inherit'});

// The helper passes ACUA_HOME on to the service it launches.
const acuaHome = path.join(directory, 'acua');
fs.mkdirSync(acuaHome);
fs.writeFileSync(path.join(acuaHome, 'config.toml'), `[apps]\nallow = ["${bundleIdentifier}"]\n`);

const mcpConfig = path.join(directory, 'mcp.json');
fs.writeFileSync(mcpConfig, JSON.stringify({mcpServers: {acua: {command: helper, args: ['mcp'], env: {ACUA_HOME: acuaHome}}}}));

// The Stop hook exactly as `hooks install` prints it, with its report kept.
const printed = JSON.parse(execFileSync(helper, ['hooks', 'install', '--client', 'claude-code'], {encoding: 'utf8'}));
const hookCommand = printed.hooks.Stop[0].hooks[0].command;
const hookLog = path.join(directory, 'stop-hook.log');
const settings = path.join(directory, 'settings.json');
fs.writeFileSync(settings, JSON.stringify({hooks: {Stop: [{hooks: [{type: 'command', command: `${hookCommand} 2>> '${hookLog}'`}]}]}}));

const eventsPath = path.join(directory, 'events.jsonl');
const events = () => fs.existsSync(eventsPath)
  ? fs.readFileSync(eventsPath, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
const fixture = spawn(binary, [directory], {stdio: 'ignore'});

let agent;
try {
  const until = Date.now() + 15000;
  while (!events().some(event => event.event === 'ready')) {
    assert.ok(Date.now() < until && fixture.exitCode === null, 'the fixture never started');
    await sleep(50);
  }

  const target = fixtureAppTarget(app);
  const prompt = [
    'Use only the tools of the acua MCP server.',
    `1. Call get_app_state with app set to exactly ${JSON.stringify(target)}.`,
    `2. Enter the text ${JSON.stringify(TEXT)} into the Message text field of that app.`,
    '3. Click the "Mark done" button in that app.',
    'Then reply with the single word DONE.',
  ].join('\n');

  agent = spawn(claude, ['-p', prompt, '--mcp-config', mcpConfig, '--strict-mcp-config', '--settings', settings,
    '--allowedTools', 'mcp__acua', '--max-turns', '15', '--output-format', 'stream-json', '--verbose'],
    {cwd: directory, env: environment, stdio: ['ignore', 'pipe', 'pipe']});
  // Streamed, so a run that hangs still shows how far the agent got.
  // A service launched through Launch Services is its own TCC responsible
  // process. Without its own Accessibility and Screen Recording grants it
  // answers "permissions are still pending" and the agent polls until the
  // timeout, so that answer ends the run at once.
  let output = '';
  let errors = '';
  let permissionsPending = false;
  agent.stderr.on('data', chunk => errors += chunk);
  const exitCode = await new Promise(resolve => {
    agent.once('exit', resolve);
    agent.stdout.on('data', chunk => {
      output += chunk;
      if (permissionsPending || !output.includes('permissions are still pending'))
        return;

      permissionsPending = true;
      agent.kill('SIGTERM');
      resolve('permissions pending');
    });
    setTimeout(() => { agent.kill('SIGTERM'); resolve('timeout'); }, 240000);
  });
  assert.ok(!permissionsPending, 'the service has no Accessibility or Screen Recording grant of its own: grant both to '
    + `"Aex Computer Use" (${serviceExecutable.replace(/\/Contents\/MacOS\/[^/]+$/, '')}) in System Settings > Privacy & Security`);
  // A killed run can end in a partial line.
  const messages = output.split('\n').filter(Boolean).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
  fs.writeFileSync(path.join(directory, 'transcript.jsonl'), output);
  const transcript = () => messages.flatMap(message => message.message?.content ?? [])
    .filter(part => part.type === 'tool_use' || part.type === 'tool_result')
    .map(part => part.type === 'tool_use' ? `-> ${part.name} ${JSON.stringify(part.input)}`
      : `<- ${JSON.stringify(part.content).slice(0, 400)}`).join('\n');
  assert.equal(exitCode, 0, `claude -p failed (${exitCode}): ${errors}\n${transcript()}`);
  const result = messages.find(message => message.type === 'result');
  assert.ok(result, `claude -p printed no result: ${transcript()}`);
  assert.equal(result.is_error, false, `${result.result}\n${transcript()}`);
  console.log(`PASS claude -p finished its turn (${result.num_turns} turns)`);

  const pressed = events().filter(event => event.event === 'pressed');
  assert.ok(pressed.length > 0, `the agent never pressed Mark done: ${JSON.stringify(events())}\n${transcript()}`);
  assert.equal(pressed.at(-1).text, TEXT, `the field held ${JSON.stringify(pressed.at(-1).text)} when Mark done was pressed`);
  console.log('PASS Claude Code typed into the app and pressed its button through the ACUA tools');

  // Claude Code runs the hook after the turn; it may still be writing.
  const hookUntil = Date.now() + 10000;
  while (!(fs.existsSync(hookLog) && fs.readFileSync(hookLog, 'utf8').includes('agent sessions')) && Date.now() < hookUntil)
    await sleep(100);
  const report = fs.existsSync(hookLog) ? fs.readFileSync(hookLog, 'utf8') : '';
  assert.match(report, /^Ended the agent sessions /m, `the Stop hook did not end a session in a running service: ${report}`);
  assert.ok(report.includes(`acua-agent-${agent.pid}-`),
    `the Stop hook did not name the session of the helper Claude Code ${agent.pid} started: ${report}`);
  console.log('PASS the Stop hook from hooks install ended the session of the helper this Claude Code started');
} finally {
  if (agent && agent.exitCode === null)
    agent.kill('SIGKILL');
  fixture.kill('SIGTERM');
  await sleep(500);
  for (const pid of servicePIDs()) {
    if (!runningBefore.has(pid))
      process.kill(pid, 'SIGTERM');
  }
}
