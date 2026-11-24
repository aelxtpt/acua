// Integration test of approvals and cancellation through the packaged MCP
// helper and the real service, which the helper launches from its own bundle
// through Launch Services, as it does for an MCP host. Nothing is clicked,
// typed or captured: every approval here is declined, cancelled or refused.
//   - a client with elicitation gets the approval form; decline and cancel
//     are reported as such;
//   - a tool call the client cancels gets no response, also once the form is
//     answered later, and the server keeps working (a client-side timeout is
//     this same cancellation);
//   - over streamable HTTP the form arrives on the session's GET stream, and
//     the answer, posted back, completes the tool call;
//   - a client without elicitation is never sent one: event_stream_start
//     opens the service's own dialog instead, which closes when the client
//     exits, and recording never starts;
//   - with --approval-prompt service, a client that declares elicitation
//     gets the service dialog too, and no elicitation.
// It runs with the physical groups because the launched service is outside
// the suite's isolation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {MCPStdioClient, PROTOCOL_VERSION, SERVERS, packagedHelper, resultText} from './mcp-stdio-client.mjs';

const APP = 'com.apple.TextEdit';
// The helper's own service, by the real path of the bundle that contains it.
const serviceExecutable = fs.realpathSync(packagedHelper())
  .replace(/\/Contents\/SharedSupport\/AexComputerUseClient\.app\/Contents\/MacOS\/AexComputerUseClient$/,
           '/Contents/MacOS/AexComputerUseService');

function servicePIDs() {
  const found = spawnSync('/usr/bin/pgrep', ['-f', serviceExecutable], {encoding: 'utf8'}).stdout;
  return new Set(found.split('\n').filter(Boolean).map(Number));
}

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const windowCounter = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'acua-mcp-elicitation-')), 'ServiceWindows');
execFileSync('swiftc', ['-O', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
  path.join(root, 'test/ServiceWindows.swift'), '-o', windowCounter], {stdio: 'inherit'});
const windowsOf = pid => Number(execFileSync(windowCounter, [String(pid)], {encoding: 'utf8'}).trim());

async function waitUntil(label, condition, seconds) {
  const until = Date.now() + seconds * 1000;
  while (!condition()) {
    assert.ok(Date.now() < until, label);
    await sleep(100);
  }
}
const runningBefore = servicePIDs();
const clients = [];

function connect(args) {
  const client = new MCPStdioClient(args);
  clients.push(client);
  return client;
}

try {
  // Decline and cancel answers.
  const asking = connect(SERVERS['computer-use']);
  await asking.initialize({elicitation: {}});
  const forms = [];
  asking.onRequest = request => {
    forms.push(request);
    return {action: forms.length === 1 ? 'decline' : 'cancel'};
  };

  const declined = await asking.callTool('get_app_state', {app: APP}, 60000);
  assert.equal(forms[0]?.method, 'elicitation/create');
  assert.equal(forms[0].params.message, 'Allow the agent to use TextEdit?');
  assert.equal(declined.isError, true);
  assert.equal(resultText(declined), `Computer Use approval denied via MCP elicitation for app '${APP}'.`);
  console.log('PASS a client with elicitation gets the approval form, and a decline is reported');

  const cancelledForm = await asking.callTool('get_app_state', {app: APP});
  assert.equal(forms.length, 2, 'a declined app is asked again');
  assert.equal(cancelledForm.isError, true);
  assert.equal(resultText(cancelledForm), `Computer Use permission request canceled for app '${APP}'.`);
  console.log('PASS cancelling the form is reported as a cancelled request');

  // Cancelling the tool call while the form is open.
  const cancelling = connect(SERVERS['computer-use']);
  await cancelling.initialize({elicitation: {}});
  const open = [];
  cancelling.onRequest = request => { open.push(request); return undefined; };

  const call = cancelling.start('tools/call', {name: 'get_app_state', arguments: {app: APP}});
  assert.ok(await cancelling.waitFor(message => message.method === 'elicitation/create', 60000), 'the form opens');
  cancelling.notify('notifications/cancelled', {requestId: call, reason: 'client timeout'});

  await sleep(2000);
  assert.equal(cancelling.messages.some(message => message.id === call), false, 'a cancelled call gets no response');
  assert.deepEqual(await cancelling.request('ping', {}), {}, 'the server keeps answering after a cancellation');

  // The user answers the form after the agent gave up: nothing comes of it.
  cancelling.send({jsonrpc: '2.0', id: open[0].id, result: {action: 'decline'}});
  await sleep(2000);
  assert.equal(cancelling.messages.some(message => message.id === call), false,
    'a late answer to the form does not revive the cancelled call');
  console.log('PASS a cancelled tool call gets no response, even after the form is answered');

  // Over HTTP: the form comes on the GET stream, the answer goes in a POST.
  const http = spawn(packagedHelper(), ['mcp', '--http', '0'], {stdio: ['ignore', 'ignore', 'pipe']});
  let announcement = '';
  http.stderr.on('data', chunk => announcement += chunk);
  try {
    await waitUntil('the HTTP server never announced itself', () => /Token: [0-9a-f]{64}/.test(announcement), 15);
    const url = announcement.match(/(http:\/\/127\.0\.0\.1:\d+\/mcp)/)[1];
    const token = announcement.match(/Token: ([0-9a-f]{64})/)[1];
    const base = {'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', Authorization: `Bearer ${token}`};
    const opened = await fetch(url, {method: 'POST', headers: base, body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'initialize',
      params: {protocolVersion: PROTOCOL_VERSION, capabilities: {elicitation: {}}, clientInfo: {name: 'acua-http-test', version: '1'}}})});
    await opened.text();
    const session = {...base, 'Mcp-Session-Id': opened.headers.get('mcp-session-id'), 'Mcp-Protocol-Version': PROTOCOL_VERSION};
    await (await fetch(url, {method: 'POST', headers: session, body: JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'})})).text();

    // Server-initiated messages arrive on the standalone GET stream.
    const events = [];
    const stream = await fetch(url, {method: 'GET', headers: session});
    const reader = stream.body.getReader();
    const decoder = new TextDecoder();
    let pending = '';
    (async () => {
      for (;;) {
        const {done, value} = await reader.read().catch(() => ({done: true}));
        if (done)
          return;
        pending += decoder.decode(value, {stream: true});
        let end;
        while ((end = pending.indexOf('\n\n')) >= 0) {
          const data = pending.slice(0, end).split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('');
          pending = pending.slice(end + 2);
          if (data)
            events.push(JSON.parse(data));
        }
      }
    })();

    const call = fetch(url, {method: 'POST', headers: session,
      body: JSON.stringify({jsonrpc: '2.0', id: 2, method: 'tools/call', params: {name: 'get_app_state', arguments: {app: APP}}})})
      .then(response => response.text());
    await waitUntil('the form never arrived on the GET stream', () => events.some(event => event.method === 'elicitation/create'), 60);
    const form = events.find(event => event.method === 'elicitation/create');
    assert.equal(form.params.message, 'Allow the agent to use TextEdit?');
    const answered = await fetch(url, {method: 'POST', headers: session,
      body: JSON.stringify({jsonrpc: '2.0', id: form.id, result: {action: 'decline'}})});
    assert.equal(answered.status, 202);
    const body = await call;
    assert.ok(body.includes(`Computer Use approval denied via MCP elicitation for app '${APP}'.`), body);
    await reader.cancel().catch(() => {});
    console.log('PASS over HTTP the form arrives on the GET stream and the posted answer completes the call');
  } finally {
    http.kill('SIGTERM');
  }

  // No elicitation for a client that did not declare it: the service asks.
  const recorder = connect(SERVERS['event-stream']);
  await recorder.initialize();
  let elicited = false;
  recorder.onRequest = request => { elicited = elicited || request.method === 'elicitation/create'; return undefined; };
  const startCall = recorder.start('tools/call', {name: 'event_stream_start', arguments: {}});
  const launched = () => [...servicePIDs()].filter(pid => !runningBefore.has(pid));
  await waitUntil('the service never started', () => launched().length === 1, 30);
  const service = launched()[0];
  await waitUntil('the service dialog never opened', () => windowsOf(service) > 0, 15);
  assert.equal(elicited, false, 'no elicitation is sent to a client without it');
  assert.equal(recorder.messages.some(message => message.id === startCall), false, 'the call waits for the dialog');
  console.log('PASS a client without elicitation gets the service dialog instead of an elicitation');

  // The helper exits unanswered: the dialog closes and nothing is recorded.
  recorder.close();
  await waitUntil('the dialog stayed open after its client exited', () => windowsOf(service) === 0, 10);
  const checker = connect(SERVERS['event-stream']);
  await checker.initialize();
  const status = JSON.parse(resultText(await checker.callTool('event_stream_status', {})));
  assert.equal(status.isRecording, false, 'recording never started');
  console.log('PASS the service dialog closes when its client exits, and recording does not start');

  // --approval-prompt service: a client that declares elicitation (as the
  // Claude app does, then declines every form unseen) still gets the service
  // dialog, and is never sent an elicitation.
  const dialogOnly = connect([...SERVERS['computer-use'], '--approval-prompt', 'service']);
  await dialogOnly.initialize({elicitation: {}});
  let dialogOnlyElicited = false;
  dialogOnly.onRequest = request => {
    dialogOnlyElicited = dialogOnlyElicited || request.method === 'elicitation/create';
    return {action: 'decline'};
  };
  const appCall = dialogOnly.start('tools/call', {name: 'get_app_state', arguments: {app: APP}});
  await waitUntil('the service dialog never opened for --approval-prompt service', () => windowsOf(service) > 0, 30);
  assert.equal(dialogOnlyElicited, false, 'no elicitation is sent with --approval-prompt service');
  assert.equal(dialogOnly.messages.some(message => message.id === appCall), false, 'the call waits for the dialog');
  dialogOnly.close();
  await waitUntil('the dialog stayed open after its client exited', () => windowsOf(service) === 0, 10);
  console.log('PASS --approval-prompt service shows the service dialog to a client with elicitation');
} finally {
  for (const client of clients)
    client.close();

  // Stop only the service this test made the helper launch.
  await sleep(500);
  for (const pid of servicePIDs()) {
    if (!runningBefore.has(pid))
      process.kill(pid, 'SIGTERM');
  }
}
