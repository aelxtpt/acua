import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, execFileSync} from 'node:child_process';
const binary = process.env.CUA_PIP_XPC_BINARY ?? '/tmp/cua-native-pip-xpc-tests';
const corpus = path.resolve(process.argv[2] ?? '../test/native-pip-xpc-protocol-corpus.json');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-pip-xpc-'));
const id = `test.acua.pip-wire.t${crypto.randomUUID().replaceAll('-', '')}`;
const app = path.join(directory, 'PIPWireHost.app');
const service = path.join(app, 'Contents/XPCServices/PIPWireChild.xpc');
const host = path.join(app, 'Contents/MacOS/PIPWireHost');
const child = path.join(service, 'Contents/MacOS/PIPWireChild');
for (const destination of [host, child]) { fs.mkdirSync(path.dirname(destination), {recursive: true}); fs.copyFileSync(binary, destination); fs.chmodSync(destination, 0o755); }
const plist = (identifier, executable, kind, extra = '') => `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${identifier}</string><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundleName</key><string>${executable}</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>${kind}</string>${extra}</dict></plist>`;
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), plist(id, 'PIPWireHost', 'APPL', '<key>LSBackgroundOnly</key><true/>'));
fs.writeFileSync(path.join(service, 'Contents/Info.plist'), plist(`${id}.child`, 'PIPWireChild', 'XPC!', '<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>dispatch_main</string></dict>'));
for (const [bundle, identifier] of [[service, `${id}.child`], [app, id]]) execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--identifier', identifier, bundle], {stdio: 'pipe'});
let hostProcess, spawnFailed = false;
const cleanup = {hostTerminal: false, childTerminal: true};
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
try {
  hostProcess = spawn(host, [directory, corpus], {stdio: ['ignore', 'inherit', 'inherit']});
  const timer = setTimeout(() => hostProcess.kill('SIGTERM'), 45000);
  const outcome = await new Promise(resolve => { hostProcess.once('error', error => { spawnFailed = true; resolve({error}); }); hostProcess.once('exit', (code, signal) => resolve({code, signal})); });
  clearTimeout(timer);
  if (outcome.error || outcome.code !== 0) throw new Error(`Owned PIP XPC fixture failed: ${JSON.stringify(outcome)}; artifacts ${directory}`);
  const result = JSON.parse(fs.readFileSync(path.join(directory, 'result.json'), 'utf8'));
  if (result.status !== 'passed' || result.hostPID === result.producerPID) throw new Error('Separate-process proof is missing');
  console.log(`NATIVE PIP XPC PASSED — artifacts: ${directory}`);
} finally {
  if (hostProcess?.pid && !spawnFailed && hostProcess.exitCode === null && hostProcess.signalCode === null) {
    hostProcess.kill('SIGKILL');
    await new Promise(resolve => hostProcess.once('exit', resolve));
  }
  cleanup.hostPID = hostProcess?.pid;
  cleanup.hostTerminal = spawnFailed || !hostProcess || hostProcess.exitCode !== null || hostProcess.signalCode !== null;
  const pidFile = path.join(directory, 'child-pid.json');
  if (fs.existsSync(pidFile)) {
    const owned = JSON.parse(fs.readFileSync(pidFile, 'utf8'));
    cleanup.childPID = owned.pid;
    for (let attempt = 0; attempt < 20; attempt++) {
      try { process.kill(owned.pid, 0); } catch (error) { if (error.code === 'ESRCH') break; throw error; }
      if (attempt === 19) {
        let command;
        try { command = execFileSync('/bin/ps', ['-p', String(owned.pid), '-o', 'comm='], {encoding: 'utf8'}).trim(); }
        catch (error) { if (!alive(owned.pid)) break; throw error; }
        if (fs.realpathSync(command) !== fs.realpathSync(child) || fs.realpathSync(owned.executable) !== fs.realpathSync(child)) throw new Error(`Owned helper identity changed; refusing cleanup; artifacts ${directory}`);
        process.kill(owned.pid, 'SIGKILL');
        cleanup.childKilledAfterIdentityCheck = true;
      } else await new Promise(resolve => setTimeout(resolve, 100));
    }
    for (let attempt = 0; attempt < 20 && alive(owned.pid); attempt++) await new Promise(resolve => setTimeout(resolve, 50));
    cleanup.childTerminal = !alive(owned.pid);
  }
  fs.writeFileSync(path.join(directory, 'cleanup.json'), JSON.stringify(cleanup));
  if (!cleanup.hostTerminal || !cleanup.childTerminal) throw new Error(`Owned fixture cleanup incomplete; artifacts ${directory}`);
}
