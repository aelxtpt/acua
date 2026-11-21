import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'cua-event-stream-ax-'));
const app=path.join(temp,'EventStreamAXFixture.app');
const macos=path.join(app,'Contents/MacOS');fs.mkdirSync(macos,{recursive:true});
fs.copyFileSync('/tmp/cua-event-stream-ax-fixture',path.join(macos,'EventStreamAXFixture'));
fs.writeFileSync(path.join(app,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.cua.event-stream-ax-fixture</string><key>CFBundleExecutable</key><string>EventStreamAXFixture</string><key>CFBundleName</key><string>EventStream AX Fixture</string><key>LSUIElement</key><true/><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync('codesign',['--force','--sign','-',app],{stdio:'inherit'});
const child=spawn(path.join(macos,'EventStreamAXFixture'),[],{stdio:['ignore','pipe','pipe']});
let output='',errors='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>errors+=d);
try {
 const end=Date.now()+12000;
 while(!output.includes('\n')){
  if(Date.now()>end || child.exitCode!==null || child.signalCode!==null)throw new Error(`Fixture not ready: ${errors}; artifacts ${temp}`);
  await new Promise(r=>setTimeout(r,25));
 }
 const ready=JSON.parse(output.split('\n')[0]);
 fs.writeFileSync(path.join(temp,'ready.json'),JSON.stringify(ready));
 execFileSync('/tmp/cua-event-stream-ax-native',[String(ready.pid)],{stdio:'inherit',timeout:25000});
 console.log(`STATIC NATIVE AX PASSED — artifacts: ${temp}`);
} finally {
 child.kill('SIGTERM');
 await new Promise(resolve=>{if(child.exitCode!==null||child.signalCode!==null)return resolve();child.once('exit',resolve);});
}
