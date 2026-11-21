import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'cua-event-stream-text-'));
function launch(directory,bundleIdentifier) {
 const app=path.join(directory,'EventStreamTextFixture.app'),macos=path.join(app,'Contents/MacOS');
 fs.mkdirSync(macos,{recursive:true});
 const binary=path.join(macos,'EventStreamTextFixture');
 fs.copyFileSync('/tmp/cua-event-stream-text-fixture',binary);
 fs.writeFileSync(path.join(app,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleIdentifier}</string><key>CFBundleExecutable</key><string>EventStreamTextFixture</string><key>CFBundleName</key><string>EventStream Text Fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
 execFileSync('codesign',['--force','--sign','-',app],{stdio:'inherit'});
 return spawn(binary,[directory],{stdio:['ignore','ignore','inherit']});
}
async function waitReady(child,directory) {
 let ready;const deadline=Date.now()+10000;
 while(!ready){
  try{ready=fs.readFileSync(path.join(directory,'events.jsonl'),'utf8').split('\n').filter(Boolean).map(JSON.parse).find(e=>e.event==='ready');}catch{}
  if(Date.now()>deadline || child.exitCode!==null || child.signalCode!==null)throw new Error(`Fixture not ready; artifacts ${directory}`);
  if(!ready)await new Promise(r=>setTimeout(r,20));
 }
 return ready;
}
const child=launch(directory,'test.acua.event-stream-text-fixture');
let other;
try {
 const ready=await waitReady(child,directory),env={...process.env};
 if(env.CUA_TEST_RECORDER_START_DEACTIVATED==='1') {
  const otherDirectory=fs.mkdtempSync(path.join(os.tmpdir(),'cua-event-stream-text-decoy-'));
  other=launch(otherDirectory,'test.acua.event-stream-text-decoy');
  await waitReady(other,otherDirectory);
  env.CUA_TEST_RECORDER_OTHER_OWNED_PID=String(other.pid);
 }
 execFileSync('/tmp/cua-event-stream-text-native',[String(child.pid),String(ready.window),directory],{stdio:'inherit',timeout:25000,env});
 console.log(`NATIVE TEXT RECORDING PASSED — artifacts: ${directory}`);
} finally {
 for(const process of [other,child].filter(Boolean)) {
  process.kill('SIGTERM');
  await new Promise(resolve=>{if(process.exitCode!==null||process.signalCode!==null)return resolve();process.once('exit',resolve);});
 }
}
