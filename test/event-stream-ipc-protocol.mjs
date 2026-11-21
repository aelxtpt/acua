import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'cua-recording-ipc-'));
const socket=path.join(directory,'service.sock');
const service=spawn(serviceTestExecutable(root),[socket],{env:serviceTestEnvironment(),stdio:['ignore','ignore','inherit']});
let checks=0;const pass=name=>{checks++;console.log(`PASS ${name}`);};
try {
 const end=Date.now()+10000;
 while(!fs.existsSync(socket)) {assert.ok(Date.now()<end,'Recording IPC socket unavailable');await new Promise(resolve=>setTimeout(resolve,20));}
 globalThis.nodeRepl={env:{ACUA_SERVICE_NATIVE_PIPE_PATH:socket},requestMeta:{},nativePipe:{createConnection:p=>new Promise((resolve,reject)=>{const s=net.createConnection(p);s.once('connect',()=>resolve(s));s.once('error',reject);})}};
 const {MacComputerUseClient}=await import('./support/js-client/client.js');
 const client=new MacComputerUseClient();
 const status=await client.request('ComputerUseIPCEventStreamStatusRequest',{});
 assert.deepEqual(status,{isRecording:false,maxDurationSeconds:1800});pass('production recording status returns the inactive shape');
 for(const value of [null,[],true,42,'empty decoder']) {
  assert.deepEqual(await client.request('ComputerUseIPCEventStreamStatusRequest',value),status);
  pass(`status accepts folded empty payload ${JSON.stringify(value)}`);
 }
 for(const reason of ['tool_stopped','debug_ui_stopped','recording_controls_stopped','recording_controls_cancelled','max_duration','service_terminated']) {
  assert.deepEqual(await client.request('ComputerUseIPCEventStreamStopRequest',{reason}),status);pass(`inactive stop retains status for ${reason}`);
 }
 for(const value of [{},null,{reason:true},{reason:'unknown'}]) {
  await assert.rejects(client.request('ComputerUseIPCEventStreamStopRequest',value),error=>error.code===-32602 && error.message==='Invalid params');pass(`stop rejects malformed reason ${JSON.stringify(value)}`);
 }
 // A missing payload fails before Start can subscribe to global native input.
 await assert.rejects(client.request('ComputerUseIPCEventStreamStartRequest',undefined),error=>error.code===-32602 && error.message==='Invalid params');pass('start requires request data before creating a recording');
 for(const value of [{session_id:true},{turn_started_at_unix_ms:'1'},{user_input_requested_during_turn:1},[],true]) {
  const agentMetadata=typeof value==='boolean'?Buffer.from(JSON.stringify(value)):value;
  await assert.rejects(client.request('ComputerUseIPCEventStreamStatusRequest',{}, {agentMetadata}),error=>error.code===-32602 && error.message==='Invalid params');pass(`transport rejects malformed metadata ${JSON.stringify(value)}`);
 }
 for(const agentMetadata of [{model:'owned',session_id:'owned-thread',turn_id:'owned-turn',turn_started_at_unix_ms:0,user_input_requested_during_turn:false},{sessionID:'ignored-camel'},null,{}]) {
  assert.deepEqual(await client.request('ComputerUseIPCEventStreamStatusRequest',{}, {agentMetadata}),status);pass('valid or unknown metadata preserves inactive status');
 }
 assert.ok(Array.isArray(await client.listApps()));pass('metadata errors preserve the native connection for later requests');
 assert.deepEqual(await client.request('ComputerUseIPCEventStreamStatusRequest',{}),status);pass('protocol checks never start a recorder on the user desktop');
 console.log(`ALL ${checks} PRODUCTION RECORDING IPC CHECKS PASSED — artifacts: ${directory}`);
}finally {
 service.kill('SIGTERM');
 await new Promise(resolve=>{if(service.exitCode!==null||service.signalCode!==null)resolve();else service.once('exit',resolve);});
}
