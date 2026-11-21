import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-sender-auth-'));
const binary = serviceTestExecutable(root);
const children = [], pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let checks = 0;
const check = (name, value) => { assert.ok(value, name); checks++; console.log(`PASS ${name}`); };
async function until(body, label) {
  const end = Date.now() + 6000;
  while (Date.now() < end) { if (await body()) return; await pause(15); }
  throw new Error(`Timeout ${label}; artifacts ${directory}`);
}
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  return Buffer.concat([header, body]);
}
const ping = { id: 1, jsonrpc: '2.0', method: 'ping', params: { clientApiVersion: 'AcuaComputerUseIPC-5' } };
function probe(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath }); let data = Buffer.alloc(0), settled = false;
    const finish = value => { if (settled) return; settled = true; clearTimeout(timer); socket.destroy(); resolve(value); };
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('Authorization did not complete in time')); }, 3000);
    socket.once('connect', () => { if (payload) socket.write(payload); });
    socket.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      if (data.length >= 4 && data.length >= 4 + data.readUInt32LE(0)) finish({ response: JSON.parse(data.subarray(4).toString('utf8')) });
    });
    socket.once('close', () => finish({ closed: true, receivedBytes: data.length }));
    socket.once('error', error => { if (error.code === 'ECONNRESET') finish({ closed: true, receivedBytes: data.length }); else { clearTimeout(timer); reject(error); } });
  });
}
async function service(name, development) {
  const socket = path.join(directory, `${name}.sock`);
  const child = spawn(binary, [socket], { env: development ? serviceTestEnvironment() : { ...process.env, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS: '0', ACUA_DIAGNOSTICS: '1' }, stdio: ['ignore', 'ignore', 'pipe'] });
  children.push(child); let errors = ''; child.stderr.on('data', data => { errors += data; });
  await until(() => fs.existsSync(socket), `${name} ready`);
  return { socket, child, errors: () => errors };
}
try {
  const peerSocket = path.join(directory, 'peer.sock');
  const peer = spawn('/tmp/cua-sender-peer-native', [peerSocket, String(process.pid)], { stdio: ['ignore', 'pipe', 'inherit'] });
  children.push(peer); let output = ''; peer.stdout.on('data', data => { output += data; });
  const peerExited = new Promise((resolve, reject) => peer.once('exit', code => code === 0 ? resolve() : reject(new Error(`peer probe exited ${code}`))));
  await until(() => fs.existsSync(peerSocket), 'native peer listener');
  await probe(peerSocket); await peerExited;
  const credentials = JSON.parse(output); fs.writeFileSync(path.join(directory, 'credentials.json'), JSON.stringify(credentials, null, 2));
  check('audit token and PID come from the actual socket peer', credentials.pidMatchesActualPeer && credentials.auditTokenBytes === 32);
  check('native peer UID matches the local test process', credentials.uidMatchesService);
  check('ad-hoc fixture is classified without a signing team', !credentials.ownSigningTeamAvailable);
  check('unsigned Node peer is classified without a signing team', !credentials.peerSigningTeamAvailable);
  // Aex Computer Use admits any process of the same local user: no signing
  // team and no signed parent are required (the unsigned Node test
  // process is exactly such a peer).
  const strict = await service('strict', false);
  check('service socket is private to its owner', (fs.statSync(strict.socket).mode & 0o777) === 0o600);
  const handshake = await probe(strict.socket, frame(ping));
  check('normal mode accepts an unsigned same-user peer', handshake.response?.result?.serverApiVersion === 'AcuaComputerUseIPC-5');
  const forged = await probe(strict.socket, frame({ ...ping, peerPID: process.pid, developerTeam: 'OTHERTEAM1', params: { ...ping.params, senderAuditToken: [], unsignedLocalClientsEnabled: true } }));
  check('client-supplied signing metadata is ignored by admission', forged.response?.result?.serverApiVersion === 'AcuaComputerUseIPC-5');
  for (let i = 0; i < 140; i++) {
    const result = await probe(strict.socket, frame(ping));
    assert.equal(result.response?.result?.serverApiVersion, 'AcuaComputerUseIPC-5');
  }
  check('140 sequential same-user handshakes return their 128 admission slots', true);
  fs.writeFileSync(path.join(directory, 'strict.stderr'), strict.errors());
  const development = await service('development', true);
  const accepted = await probe(development.socket, frame(ping));
  check('explicit same-user development mode permits the local handshake', accepted.response?.result?.serverApiVersion === 'AcuaComputerUseIPC-5');
  const diagnostic = JSON.parse(execFileSync(binary, ['--diagnostics'], { encoding: 'utf8', env: { ...process.env, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS: '0' } }));
  check('unsigned-client opt-in is absent in normal startup configuration', diagnostic.unsignedLocalClientsEnabled === false);
  console.log(`ALL ${checks} NATIVE SENDER AUTHORIZATION CHECKS PASSED — artifacts: ${directory}`);
} finally { for (const child of children) child.kill('SIGTERM'); }
