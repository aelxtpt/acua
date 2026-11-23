// Integration test of approvals and cancellation through the packaged MCP
// helper and the real service, which the helper launches from its own bundle
// through Launch Services, as it does for an MCP host. Nothing is clicked,
// typed or captured: every approval here is declined, cancelled or refused.
//   - a client with elicitation gets the approval form; decline and cancel
//     are reported as such;
//   - a tool call the client cancels gets no response, also once the form is
//     answered later, and the server keeps working (a client-side timeout is
//     this same cancellation);
//   - a client without elicitation is never sent one: event_stream_start
//     fails at once and recording never starts.
// It runs with the physical groups because the launched service is outside
// the suite's isolation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {MCPStdioClient, SERVERS, packagedHelper, resultText} from './mcp-stdio-client.mjs';

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

  // No elicitation for a client that did not declare it.
  const recorder = connect(SERVERS['event-stream']);
  await recorder.initialize();
  let elicited = false;
  recorder.onRequest = request => { elicited = request.method === 'elicitation/create'; return undefined; };
  const start = await recorder.callTool('event_stream_start', {});
  assert.equal(start.isError, true, resultText(start));
  assert.match(resultText(start), /needs the user's approval through MCP elicitation, which this MCP client did not declare/);
  assert.equal(elicited, false, 'no elicitation is sent to a client without it');
  const status = JSON.parse(resultText(await recorder.callTool('event_stream_status', {})));
  assert.equal(status.isRecording, false, 'recording never started');
  console.log('PASS a client without elicitation is never sent one, and recording does not start');
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
