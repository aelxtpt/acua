import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync,execFileSync} from 'node:child_process';
const binary=process.env.CUA_NATIVE_PRODUCER_BINARY ?? '/tmp/cua-event-stream-native-producer-native';
const inputBinary=process.env.CUA_NATIVE_PRODUCER_INPUT_BINARY ?? '/tmp/cua-event-stream-native-producer-input-fixture';
const preflight=spawnSync(binary,['--preflight'],{encoding:'utf8'});
if(preflight.status!==0){if(preflight.stderr)process.stderr.write(preflight.stderr);process.exit(preflight.status??1);}
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'cua-native-producer-'));
const app=path.join(directory,'EventStreamProducerFixture.app'),macos=path.join(app,'Contents/MacOS');
fs.mkdirSync(macos,{recursive:true});const fixture=path.join(macos,'EventStreamProducerFixture');
fs.copyFileSync(inputBinary,fixture);
fs.writeFileSync(path.join(app,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.acua.event-stream-producer-fixture</string><key>CFBundleExecutable</key><string>EventStreamProducerFixture</string><key>CFBundleName</key><string>EventStream Producer Fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
execFileSync('codesign',['--force','--sign','-',app],{stdio:'inherit'});
const child=spawn(fixture,[directory],{stdio:['ignore','ignore','inherit']});
try {
 let ready;const deadline=Date.now()+10000;
 while(!ready){
  try{ready=fs.readFileSync(path.join(directory,'events.jsonl'),'utf8').split('\n').filter(Boolean).map(JSON.parse).find(e=>e.event==='ready');}catch{}
  if(Date.now()>deadline||child.exitCode!==null||child.signalCode!==null)throw new Error(`Owned producer fixture not ready; artifacts ${directory}`);
  if(!ready)await new Promise(resolve=>setTimeout(resolve,20));
 }
 const result=spawnSync(binary,[String(child.pid),String(ready.window),directory],{stdio:'inherit',timeout:70000});
 if(result.error)throw result.error;
 if(result.status!==0)process.exitCode=result.status??1;
 else console.log(`NATIVE PRODUCER PASSED — artifacts: ${directory}`);
} finally {
 if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
 await new Promise(resolve=>{if(child.exitCode!==null||child.signalCode!==null)resolve();else child.once('exit',resolve);});
}
