import os from 'node:os';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-messages-ipc-'));
const socket = path.join(directory, 'service.sock');
const child = spawn(serviceTestExecutable(root), [socket], {
  env: serviceTestEnvironment(), stdio: ['ignore', 'ignore', 'inherit'],
});
try {
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(socket)) {
    assert.equal(child.exitCode, null, 'Service exited before accepting requests');
    assert.ok(Date.now() < deadline, 'Messages IPC socket unavailable');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  globalThis.nodeRepl = {
    env: {ACUA_SERVICE_NATIVE_PIPE_PATH: socket}, requestMeta: {},
    nativePipe: {createConnection: name => new Promise((resolve, reject) => {
      const connection = net.createConnection(name);
      connection.once('connect', () => resolve(connection));
      connection.once('error', reject);
    })},
  };
  const {MacComputerUseClient} = await import('./support/js-client/client.js');
  const client = new MacComputerUseClient();
  const route = 'ComputerUseIPCMessagesReadImageRequest';
  const typedError = error => error.code === -32602 && error.message === 'Invalid params';
  // Invalid wire data never evaluates a native permission or opens a database.
  for (const [label, body] of [
    ['missing', undefined], ['null', null],
    ['missing ID', {}], ['invalid ID type', {id: 1}],
  ]) {
    await assert.rejects(client.request(route, body), typedError);
    console.log('PASS Messages socket rejects ' + label);
  }
  const readRoute = 'ComputerUseIPCMessagesReadMessagesRequest';
  for (const body of [{chatGUID: 'owned', limit: 2}, {chatGUID: 'owned', limit: 2, unreadOnly: false, cursor: []}]) {
    await assert.rejects(client.request(readRoute, body), typedError);
  }
  console.log('PASS Messages socket validates the read page before opening the database');
  for (const [route, body] of [
    ['ComputerUseIPCMessagesSearchChatsRequest', {query: 7, limit: 2}],
    ['ComputerUseIPCMessagesFindChatsRequest', {participants: [], limit: 2}],
  ]) {
    await assert.rejects(client.request(route, body), typedError);
  }
  console.log('PASS Messages socket validates chat discovery before opening the database');
  const searchRoute = 'ComputerUseIPCMessagesSearchMessagesRequest';
  const search = {text: 'owned', chatGUIDs: [], participants: [], exactParticipants: false, limit: 2};
  for (const body of [{...search, chatGUIDs: 'owned'}, {...search, cursor: []}]) {
    await assert.rejects(client.request(searchRoute, body), typedError);
  }
  console.log('PASS Messages socket validates message search before opening the database');
  const activityRoute = 'ComputerUseIPCMessagesCountActivityRequest';
  const activity = {interval: 'total', chatGUIDs: [], breakdown: 'overall', rankBy: 'total', chatLimit: 10};
  for (const body of [{...activity, interval: 'hour'}, {...activity, chatLimit: '10'}]) {
    await assert.rejects(client.request(activityRoute, body), typedError);
  }
  console.log('PASS Messages socket validates activity before opening the database');
  const prepareRoute = 'ComputerUseIPCMessagesPrepareSendRequest';
  for (const body of [{text: 'draft', attachments: []}, {recipients: [], attachments: [{filename: 7}]}]) {
    await assert.rejects(client.request(prepareRoute, body), typedError);
  }
  console.log('PASS Messages socket validates send preparation before opening the database');
  const commitRoute = 'ComputerUseIPCMessagesCommitSendRequest';
  await assert.rejects(client.request(commitRoute, {planID: 'invalid'}), typedError);
  await assert.rejects(client.request(commitRoute, {planID: 'A1111111-1111-1111-1111-111111111111', text: 'owned'}), error =>
    error.code === -10027 && error.message === 'Messages send plan is unavailable (missing).');
  console.log('PASS Messages socket rejects invalid or unknown commits before permissions');
  const descriptorCheck = spawnSync('python3', ['-c', `
import array, json, select, socket, struct, sys, tempfile
def read(peer, count):
    data = b''
    while len(data) < count:
        piece = peer.recv(count - len(data))
        assert piece, data
        data += piece
    return data
with socket.socket(socket.AF_UNIX) as peer, tempfile.TemporaryFile() as attachment:
    attachment.write(b'owned file')
    peer.settimeout(3)
    peer.connect(sys.argv[1])
    def rpc(i, method, params, transfer=False):
        body = json.dumps(dict(id=i, jsonrpc='2.0', method=method, params=params)).encode()
        header = struct.pack('<I', len(body))
        if transfer:
            # Attach rights after a partial header to exercise fragmented ancillary framing.
            peer.sendall(header[:1])
            fds = array.array('i', [attachment.fileno()])
            assert peer.sendmsg([header[1:]], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)]) == 3
            peer.sendall(body)
        else:
            peer.sendall(header + body)
        length = struct.unpack('<I', read(peer, 4))[0]
        return json.loads(read(peer, length))
    base = dict(clientApiVersion='AcuaComputerUseIPC-5')
    assert rpc(1, 'ping', base, True)['result']['serverApiVersion'] == base['clientApiVersion']
    commit = dict(base, requestType='ComputerUseIPCMessagesCommitSendRequest',
                  request=dict(planID='A1111111-1111-1111-1111-111111111111', text='owned'))
    assert rpc(2, 'request', commit, True)['error']['code'] == -10027
    assert rpc(3, 'ping', base)['result']['serverApiVersion'] == base['clientApiVersion']
with socket.socket(socket.AF_UNIX) as peer, tempfile.TemporaryFile() as attachment:
    peer.settimeout(3)
    peer.connect(sys.argv[1])
    fds = array.array('i', [attachment.fileno()] * 65)
    body = json.dumps(dict(id=1, jsonrpc='2.0', method='ping',
                           params=dict(clientApiVersion='AcuaComputerUseIPC-5'))).encode()
    assert peer.sendmsg([struct.pack('<I', len(body))], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)]) == 4
    # The service waits for the body even when more than 64 rights accompany its header.
    assert not select.select([peer], [], [], 0.1)[0], 'premature reply before body'
    peer.sendall(body)
    length = struct.unpack('<I', read(peer, 4))[0]
    assert json.loads(read(peer, length))['result']['serverApiVersion'] == 'AcuaComputerUseIPC-5'
`, socket], {encoding: 'utf8', timeout: 7000});
  assert.equal(descriptorCheck.status, 0, descriptorCheck.stderr || String(descriptorCheck.error));
  console.log('PASS Extra descriptors preserve replies across fragmented frames');
  assert.deepEqual(await client.request('ComputerUseIPCTurnEndedRequest', {threadID: 'owned'}), {});
  console.log('PASS Messages wire errors preserve the service connection');
} finally {
  child.kill('SIGTERM');
  await new Promise(resolve => {
    if (child.exitCode !== null || child.signalCode !== null) resolve();
    else child.once('exit', resolve);
  });
  fs.rmSync(directory, {recursive: true, force: true});
}
