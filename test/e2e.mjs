import os from 'node:os';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import net from "node:net";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const socketDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-e2e-'));
const sockPath = path.join(socketDirectory, 'service.sock');
try { fs.unlinkSync(sockPath); } catch {}

const service = spawn(serviceTestExecutable(root), [sockPath], { env: serviceTestEnvironment(), stdio: ["ignore", "pipe", "pipe"] });
service.stdout.on("data", (d) => process.stdout.write(`[svc] ${d}`));
service.stderr.on("data", (d) => process.stderr.write(`[svc-err] ${d}`));

async function waitForSocket(p, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (fs.existsSync(p)) { try { const s = net.connect(p); await new Promise((r, j) => { s.once("connect", r); s.once("error", j); }); s.end(); return; } catch {} }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("service socket did not appear");
}

// --- nodeRepl shim: exactly the surface the client touches ---
globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: sockPath },
  requestMeta: {},
  nativePipe: {
    createConnection(p) {
      return new Promise((resolve, reject) => {
        const socket = net.createConnection({ path: p });
        socket.once("connect", () => resolve(socket));
        socket.once("error", reject);
      });
    },
  },
  createElicitation: async (req) => {
    console.log(`[elicit] ${req.message}`);
    return { action: "accept" };
  },
  setResponseMeta: () => {},
};

const out = (label, value) => console.log(`\n### ${label}\n${JSON.stringify(value, null, 2)}`);

try {
  await waitForSocket(sockPath);
  const { MacComputerUseClient } = await import("./support/js-client/client.js");
  const client = new MacComputerUseClient();

  const pong = await client.getAppPolicy("Finder");
  assert.equal(pong.decision, "allowed");
  out("getAppPolicy(Finder)", pong);

  const apps = await client.listApps();
  assert.ok(Array.isArray(apps) && apps.length > 0);
  out(`listApps (${apps.length} apps, first 5)`, apps.slice(0, 5));

  let state;
  try {
    state = await client.getAppState("Finder");
    assert.equal(state.app.bundleIdentifier, "com.apple.finder");
    assert.ok(Number.isInteger(state.app.pid) && state.app.pid > 0);
    assert.ok(typeof state.appSnapshot?.text === "string" && state.appSnapshot.text.length > 0);
    out("getAppState(Finder) [truncated]", {
      app: state.app,
      text: (state.appSnapshot?.text ?? "").slice(0, 600),
      screenshot: state.appSnapshot?.screenshot?.url ? `${state.appSnapshot.screenshot.url.slice(0, 40)}...(${state.appSnapshot.screenshot.url.length} bytes)` : null,
    });
  } catch (e) {
    console.error(`getAppState(Finder) failed; native end-to-end validation did not pass: ${e.name} code=${e.code} — ${e.message}`);
    throw e;
  }

  console.log("\n=== PROTOCOL E2E OK ===");
} finally {
  service.kill("SIGTERM");
}
