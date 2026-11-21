import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "cua-lifecycle-"));
const socketPath = path.join(directory, "service.sock");
const service = spawn(serviceTestExecutable(root), [socketPath], { env: serviceTestEnvironment(), stdio: ["ignore", "ignore", "pipe"] });
let errors = "";
service.stderr.on("data", value => { errors += value; });
globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socketPath }, requestMeta: {},
  nativePipe: { createConnection: p => new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: p });
    socket.once("connect", () => resolve(socket)); socket.once("error", reject);
  }) },
};
const { MacComputerUseClient } = await import("./support/js-client/client.js");
const client = new MacComputerUseClient();
const pass = name => console.log(`PASS ${name}`);

async function checkReviewLifecycle() {
  const bundle = 'test.acua.inactive-lifecycle-fixture';
  const fixture = path.join(directory, 'InactiveLifecycleFixture.app');
  const contents = path.join(fixture, 'Contents');
  fs.mkdirSync(contents, { recursive: true });
  fs.writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>${bundle}</string>
    <key>CFBundleName</key><string>Inactive Lifecycle Fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>`);
  const alias = path.join(directory, 'Alias.app');
  fs.symlinkSync(fixture, alias, 'dir');
  const policy = await client.getAppPolicy(fixture);
  assert.equal(policy.target.bundleIdentifier, bundle);
  const app = policy.target.appPath;
  const action = (identifier = app) => client.typeText({ app: identifier, text: '' });
  const expect = (request, code, label) => assert.rejects(request, error => {
    assert.equal(error.code, code, `${label}: ${error.message}`);
    return true;
  });

  await expect(() => action(), -10011, 'canonical target before stop');
  assert.deepEqual(await client.stopApp(alias), { active: false });
  await expect(() => action(alias), -10011, 'stop of a raw alias does not mark the canonical instance');
  pass('stop records the raw identifier and does not resolve aliases');

  assert.deepEqual(await client.stopApp(app), { active: false });
  await expect(() => action(), -10012, 'action after canonical stop');
  await expect(() => client.modifyApp(app, 'activate'), -10012, 'modify after canonical stop');
  await expect(() => action(alias), -10012, 'alias resolves to the stopped canonical instance');
  pass('canonical stop prevents action and modification through the instance manager');

  for (const [name, request] of [['start', () => client.startApp(app)], ['state', () => client.getAppState(app)]]) {
    // The native path prepares a launch before checking the stopped instance.
    await assert.rejects(request, error => {
      assert.equal(error.code, -10005, `${name}: ${error.message}`);
      assert.match(error.message, /-10827/, name);
      return true;
    });
  }
  pass('start and state requests preserve launch-before-stop ordering on a bundle without an executable');

  assert.deepEqual(await client.stopApp(app), { active: false });
  assert.deepEqual(await client.stopApp(path.join(directory, 'MissingLifecycleFixture.app')), { active: false });
  assert.deepEqual(await client.stopApp('com.apple.Terminal'), { active: false });
  assert.ok((await client.listApps()).every(entry => entry.bundleIdentifier !== bundle || !entry.isRunning));
  pass('stop is idempotent and does not launch, terminate or apply target resolution to inactive identifiers');
  return app;
}

async function checkLegacyLifecycle(apps) {
  const before = apps.some(app => app.bundleIdentifier === "com.apple.finder" && app.isRunning);
  const stopped = await client.stopApp("Finder");
  assert.deepEqual(stopped, { active: false });
  pass("stop without a prior session returns the inactive-state shape");
  for (const [name, request] of [
    ["start", () => client.startApp("Finder")],
    ["state requery", () => client.getAppState("Finder")],
    ["input", () => client.typeText({ app: "Finder", text: "" })],
    ["modify activate", () => client.modifyApp("Finder", "activate")],
  ]) {
    await assert.rejects(request(), error => error.code === -10012);
    pass(`a user-stopped session rejects ${name}`);
  }
  assert.deepEqual(await client.stopApp("Finder"), { active: false });
  const after = (await client.listApps()).some(app => app.bundleIdentifier === "com.apple.finder" && app.isRunning);
  assert.equal(after, before);
  pass("repeated stop is idempotent and does not terminate the target app");
  await assert.rejects(client.stopApp("com.apple.Terminal"), error => error.code === -10006);
  pass("stop obeys native target policy");
  return "Finder";
}

try {
  const limit = Date.now() + 8000;
  while (!fs.existsSync(socketPath)) {
    assert.ok(Date.now() < limit && service.exitCode === null, `service did not start: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  const apps = await client.listApps();
  assert.ok(apps.length > 0);
  assert.ok(apps.every(app => typeof app.isRunning === "boolean" && typeof app.isFrontmost === "boolean"));
  const firstInactive = apps.findIndex(app => !app.isRunning);
  if (firstInactive !== -1) {
    assert.ok(apps.slice(firstInactive).every(app => !app.isRunning && !app.isFrontmost &&
      Number.isFinite(app.lastUsedDate) && typeof app.appPath === "string"));
  }
  assert.ok(apps.every((app, index) => !app.isFrontmost || index === 0));
  pass("app catalog marks the foreground and places running apps before recent inactive apps");
  const review = Boolean(process.env.CUA_REVIEW_LAUNCHER);
  const testApp = review ? await checkReviewLifecycle() : await checkLegacyLifecycle(apps);
  for (const modification of [{ hide: {} }, { activate: {}, deactivate: {} }, { activate: true }]) {
    await assert.rejects(client.request("ComputerUseIPCAppModifyRequest", { app: testApp, modification }), error => error.code === -32602 && error.message === 'Invalid params');
  }
  pass("invalid and ambiguous session modifications fail before side effects");
  const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ["--diagnostics"], { encoding: "utf8" }));
  if (diagnostics.screenLocked) {
    const window = await client.getFrontmostWindow();
    if (review) {
      // The native route reads the selected window even when the console is locked.
      assert.ok(window === null || (typeof window.bundleIdentifier === 'string' && window.bundleIdentifier.length > 0 &&
        typeof window.name === 'string' && (window.windowTitle === undefined || typeof window.windowTitle === 'string')));
      pass(window?.bundleIdentifier === 'com.apple.loginwindow' ? 'native frontmost window identifies the lock screen' :
        'native frontmost window preserves the optional response on a locked desktop');
    } else {
      assert.equal(window, null);
      pass("legacy frontmost-window request returns null for a locked desktop");
    }
  }
  console.log(`ALL LIFECYCLE IPC CHECKS PASSED — artifacts: ${directory}`);
} finally {
  for (const transport of client.transports.values()) { try { (await transport).close(); } catch {} }
  service.kill("SIGTERM");
}
