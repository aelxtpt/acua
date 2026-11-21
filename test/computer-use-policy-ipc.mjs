// Integration test: the real service answers ComputerUseIPCAppPolicyRequest from
// $ACUA_HOME/config.toml. Edits apply to the next request, an invalid file fails
// closed, and the service never writes the file. It also proves the standalone
// contract: no Codex CLI is executed, nothing is written to CODEX_HOME, and the
// service holds no network connection.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';

const UNKNOWN_ERROR = -10005;
const INVALID_APP = -10010;
const TARGET_BUNDLE = 'com.aex.computeruse.policy-wire';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-policy-wire-'));

const app = path.join(directory, 'Owned.app');
fs.mkdirSync(path.join(app, 'Contents'), {recursive: true});
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${TARGET_BUNDLE}</string>
<key>CFBundleName</key><string>Owned</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>http</string></array></dict></array>
</dict></plist>`);

const cases = [
  {name: 'no-config-file', config: null, decision: 'allowed', persistent: true},
  {name: 'disabled', config: '[apps]\nenabled = false\n', decision: 'denied', persistent: true},
  {name: 'default-deny', config: '[apps]\ndefault_access = "deny"\n', decision: 'denied', persistent: true},
  {name: 'default-deny-with-allow-list', config: `[apps]\ndefault_access = "deny"\nallow = ["${TARGET_BUNDLE}"]\n`, decision: 'allowed', persistent: true},
  {name: 'deny-list', config: `[apps]\ndeny = ["${TARGET_BUNDLE}"]\n`, decision: 'denied', persistent: true},
  {name: 'persistent-approval-off', config: '[apps]\nallow_persistent_approval = false\n', decision: 'allowed', persistent: false},
  {name: 'invalid-file', config: '[apps]\ndefualt_access = "deny"\n', error: UNKNOWN_ERROR},
];

// A Codex CLI stand-in that leaves a marker if anything ever executes it.
const codexMarker = path.join(directory, 'codex-was-executed');
const codexSentinel = path.join(directory, 'codex-sentinel');
fs.writeFileSync(codexSentinel, `#!/bin/sh\ntouch '${codexMarker}'\nexit 1\n`, {mode: 0o755});

function networkConnections(pid) {
  // lsof exits 1 when the process has no matching (internet) descriptor.
  const result = spawnSync('/usr/sbin/lsof', ['-nP', '-a', '-i', '-p', String(pid)], {encoding: 'utf8'});
  return result.stdout.trim();
}

function listFiles(folder) {
  if (!fs.existsSync(folder))
    return [];

  return fs.readdirSync(folder, {recursive: true}).sort();
}

for (const test of cases) {
  const acuaHome = path.join(directory, test.name, 'acua');
  const codexHome = path.join(directory, test.name, 'codex');
  fs.mkdirSync(acuaHome, {recursive: true});
  fs.mkdirSync(codexHome, {recursive: true});

  const configFile = path.join(acuaHome, 'config.toml');
  if (test.config !== null)
    fs.writeFileSync(configFile, test.config);

  // Unix socket paths are limited to 104 bytes, so the name stays short.
  const endpoint = path.join(directory, cases.indexOf(test) + '.sock');
  const server = spawn(serviceTestExecutable(root), [endpoint], {
    env: serviceTestEnvironment({ACUA_HOME: acuaHome, CODEX_HOME: codexHome, CODEX_CLI_PATH: codexSentinel}),
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let errors = '';
  server.stderr.on('data', chunk => errors += chunk);

  let socket;
  try {
    const deadline = Date.now() + 8000;
    while (!fs.existsSync(endpoint)) {
      assert.ok(server.exitCode === null && server.signalCode === null && Date.now() < deadline, `service did not start (exit ${server.exitCode}, signal ${server.signalCode}): ${errors}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }

    socket = net.createConnection(endpoint);
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });

    let data = Buffer.alloc(0);
    const replies = [];
    socket.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      while (data.length >= 4 && data.length >= data.readUInt32LE() + 4) {
        const length = data.readUInt32LE();
        replies.push(JSON.parse(data.subarray(4, length + 4)));
        data = data.subarray(length + 4);
      }
    });

    let id = 0;
    async function policy(target) {
      const message = {id: ++id, jsonrpc: '2.0', method: 'request', params: {
        clientApiVersion: 'AcuaComputerUseIPC-5', requestType: 'ComputerUseIPCAppPolicyRequest', request: {app: target}}};
      const body = Buffer.from(JSON.stringify(message));
      const header = Buffer.alloc(4);
      header.writeUInt32LE(body.length);
      socket.write(Buffer.concat([header, body]));

      const until = Date.now() + 8000;
      while (!replies.length) {
        assert.ok(Date.now() < until, errors);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      return replies.shift();
    }

    const configBefore = test.config === null ? null : fs.readFileSync(configFile, 'utf8');

    const missing = await policy(TARGET_BUNDLE + '.nonexistent');
    assert.equal(missing.error.code, INVALID_APP, 'target lookup errors come before policy errors');

    let reply = await policy(app);
    if (test.error) {
      assert.equal(reply.error.code, test.error);
      assert.ok(reply.error.message.includes(configFile), 'the error names the configuration file');
      assert.ok(reply.error.message.includes('apps.defualt_access'), 'the error names the bad setting');

      fs.writeFileSync(configFile, '[apps]\n');
      reply = await policy(app);
      assert.equal(reply.result.decision, 'allowed', 'fixing the file applies without a restart');
    } else {
      assert.equal(reply.result.decision, test.decision);
      assert.equal(reply.result.allowPersistentApproval, test.persistent);
      assert.equal(reply.result.target.risk, 'high');
      assert.ok(reply.result.target.warningSubtitle.includes('prompt injection'));
      assert.equal(reply.result.target.allowPersistentApproval, undefined);

      const configAfter = test.config === null ? null : fs.readFileSync(configFile, 'utf8');
      assert.equal(configAfter, configBefore, 'the service never rewrites config.toml');
      assert.equal(fs.existsSync(configFile), test.config !== null, 'the service never creates config.toml');

      fs.writeFileSync(configFile, '[apps]\nenabled = false\n');
      assert.equal((await policy(app)).result.decision, 'denied', 'an edit applies to the next request');
    }

    assert.deepEqual(listFiles(codexHome), [], 'nothing is written to CODEX_HOME');
    assert.equal(fs.existsSync(codexMarker), false, 'the Codex CLI is never executed');
    assert.equal(networkConnections(server.pid), '', 'the service holds no network connection');
    console.log('PASS local policy from config.toml:', test.name);
  } finally {
    socket?.destroy();
    server.kill('SIGTERM');
    if (server.exitCode === null && server.signalCode === null)
      await new Promise(resolve => server.once('exit', resolve));
  }
}
console.log('Policy IPC artifacts:', directory);
