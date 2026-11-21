import os from 'node:os';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import net from "node:net";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const socketDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-protocol-'));
const sockPath = path.join(socketDirectory, 'service.sock');
try { fs.unlinkSync(sockPath); } catch {}
const service = spawn(serviceTestExecutable(root), [sockPath], { env: serviceTestEnvironment(), stdio: ["ignore", "ignore", "ignore"] });

async function waitForSocket(p, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (fs.existsSync(p)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("socket missing");
}

globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: sockPath },
  requestMeta: {},
  nativePipe: {
    createConnection(p) {
      return new Promise((resolve, reject) => {
        const s = net.createConnection({ path: p });
        s.once("connect", () => resolve(s));
        s.once("error", reject);
      });
    },
  },
  createElicitation: async () => ({ action: "accept" }),
  setResponseMeta: () => {},
};

const results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok }); console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " — " + detail : ""}`); };

try {
  await waitForSocket(sockPath);
  const { MacComputerUseClient } = await import("./support/js-client/client.js");

  // 1. version mismatch → -10013
  const bad = new MacComputerUseClient({ apiVersion: "AcuaComputerUseIPC-4" });
  try { await bad.listApps(); check("version mismatch rejected", false, "no error"); }
  catch (e) { check("version mismatch rejected", e.code === -10013, `code=${e.code}`); }

  const client = new MacComputerUseClient();

  // 2. unknown request type → -10003
  try { await client.request("ComputerUseIPCDoesNotExist", {}); check("unknown request type rejected", false); }
  catch (e) { check("unknown request type rejected", e.code === -10003, `code=${e.code}`); }

  // 3. app start (activate)
  await client.startApp("Safari");
  check("startApp(Safari)", true);

  // 4. perform action: type_text (CGEvent path, no AX needed)
  try { await client.typeText({ app: "Safari", text: "" }); check("typeText empty ok", true); }
  catch (e) { check("typeText empty ok", false, `${e.name} ${e.code} ${e.message}`); }

  // 5. Start activates the controller; no tree has been observed in this service.
  // Unknown IDs after an observation are covered by the native input fixture.
  try { await client.setValue({ app: "Safari", elementIndex: 99999, value: "x" }); check("element action requires an observed tree", false, "no error"); }
  catch (e) { check("element action requires an observed tree", e.code === -10011, `code=${e.code} ${e.message}`); }

  // 6. audio start (needs Screen Recording) → expect permissions error or ok
  try { await client.startAudioRecording({ maxDurationMilliseconds: 500 }); check("startAudioRecording", true, "started"); await client.stopAudioRecording(); }
  catch (e) { check("startAudioRecording permission-gated", e.code === -10009 || e.code === -10014 || e.code === -10011, `code=${e.code} ${e.message}`); }

  // 7. list_apps returns the running apps
  const apps = await client.listApps();
  check("listApps returns array", Array.isArray(apps) && apps.length > 0, `${apps.length} apps`);

  // 8. policy allows Finder; get_app_state succeeds or is gated by permissions
  const policy = await client.getAppPolicy("Finder");
  check("getAppPolicy(Finder) allowed", policy.decision === "allowed", String(policy.decision));
  try { await client.getAppState("Finder"); check("getAppState", true); }
  catch (e) { check("getAppState permission-gated", e.code === -10009 || e.code === -10014, `code=${e.code} ${e.message}`); }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exitCode = failed.length ? 1 : 0;
} finally {
  service.kill("SIGTERM");
}
