import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import net from "node:net";
import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "cua-audio-"));
const sockPath = path.join(temp, "ipc");
const service = spawn(serviceTestExecutable(root), [sockPath], {
  env: serviceTestEnvironment({ CODEX_HOME: temp }),
  stdio: ["ignore", "ignore", "ignore"],
});
async function waitForSocket(p, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (fs.existsSync(p)) return; await new Promise((r) => setTimeout(r, 100)); }
  throw new Error("socket missing");
}
globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: sockPath },
  requestMeta: {},
  nativePipe: { createConnection: (p) => new Promise((res, rej) => { const s = net.createConnection({ path: p }); s.once("connect", () => res(s)); s.once("error", rej); }) },
  createElicitation: async () => ({ action: "accept" }),
  setResponseMeta: () => {},
};
try {
  await waitForSocket(sockPath);
  const { MacComputerUseClient } = await import("./support/js-client/client.js");
  const client = new MacComputerUseClient();
  await assert.rejects(client.startAudioRecording({ maxDurationMilliseconds: "5000" }), { code: -32602, message: 'Invalid params' });
  console.log("PASS invalid audio duration type is rejected over the socket");
  await client.startAudioRecording({ maxDurationMilliseconds: 5000 });
  console.log("recording started");
  await new Promise((r) => setTimeout(r, 1200));
  const result = await client.stopAudioRecording();
  console.log("stop result:", JSON.stringify(result));
  const url = new URL(result.url);
  const file = fileURLToPath(url);
  let buf;
  try { buf = fs.readFileSync(file); }
  finally { fs.rmSync(file, { force: true }); }
  const riff = buf.subarray(0, 4).toString("ascii");
  const wave = buf.subarray(8, 12).toString("ascii");
  // Parse fmt chunk for sample rate / channels.
  let sampleRate = 0, channels = 0, bits = 0;
  for (let i = 12; i + 8 <= buf.length;) {
    const id = buf.subarray(i, i + 4).toString("ascii");
    const size = buf.readUInt32LE(i + 4);
    if (id === "fmt ") { channels = buf.readUInt16LE(i + 10); sampleRate = buf.readUInt32LE(i + 12); bits = buf.readUInt16LE(i + 22); }
    if (id === "data") break;
    i += 8 + size + (size % 2);
  }
  const ok = riff === "RIFF" && wave === "WAVE" && buf.length > 44 && sampleRate === 24000 && channels === 2 && bits === 16;
  console.log(`${ok ? "PASS" : "FAIL"} wav: RIFF=${riff} WAVE=${wave} bytes=${buf.length} rate=${sampleRate} ch=${channels} bits=${bits} file=${file}`);
  const owner = { agentMetadata: { session_id: "audio-fixture-owner" } };
  await client.startAudioRecording({ maxDurationMilliseconds: 750 }, owner);
  await new Promise((r) => setTimeout(r, 1200));
  await assert.rejects(client.stopAudioRecording({ agentMetadata: { session_id: "audio-fixture-other" } }), { code: -10005 });
  console.log("PASS a different session cannot claim the auto-stopped recording");
  const autoStopped = fileURLToPath((await client.stopAudioRecording(owner)).url);
  try {
    const output = fs.readFileSync(autoStopped);
    assert.equal(output.subarray(0, 4).toString("ascii"), "RIFF");
    assert.equal(output.subarray(8, 12).toString("ascii"), "WAVE");
  } finally { fs.rmSync(autoStopped, { force: true }); }
  console.log("PASS real socket retrieves the WAV after automatic stop");
  await assert.rejects(client.stopAudioRecording(), { code: -10005, message: "Computer Use server error -10005: noActiveRecording" });
  console.log("PASS real socket cannot claim an audio file twice");

  const threadID = "audio-fixture-turn-thread";
  const turnID = "audio-fixture-recording-turn";
  const turn = { agentMetadata: { session_id: threadID, turn_id: turnID } };
  const end = (threadID, turnID) => client.request("ComputerUseIPCTurnEndedRequest", { threadID, turnID });
  await client.startAudioRecording({ maxDurationMilliseconds: 5000 }, turn);
  await end(threadID, "audio-fixture-different-turn");
  await assert.rejects(client.startAudioRecording({ maxDurationMilliseconds: 5000 }, turn), { code: -10005, message: "Computer Use server error -10005: recordingAlreadyActive" });
  console.log("PASS ending a different turn leaves the real audio recording active");
  assert.deepEqual(await end(threadID, turnID), {});
  await assert.rejects(client.stopAudioRecording({ agentMetadata: { session_id: threadID } }), { code: -10005, message: "Computer Use server error -10005: noActiveRecording" });
  await assert.rejects(client.startAudioRecording({ maxDurationMilliseconds: 5000 }, turn), { code: -10021 });
  console.log("PASS ending the owning turn discards the recording and rejects a new Start on that turn");
  process.exitCode = ok ? 0 : 1;
} catch (e) {
  console.log(`AUDIO TEST BLOCKED: ${e.name} code=${e.code} — ${e.message}`);
  process.exitCode = 2;
} finally {
  if (service.exitCode === null && service.signalCode === null) {
    service.kill("SIGTERM");
    await new Promise(resolve => service.once("exit", resolve));
  }
  fs.rmSync(temp, { recursive: true, force: true });
}
