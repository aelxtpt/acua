import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable } from './service-test-environment.mjs';
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ["--diagnostics"], { encoding: "utf8" }));
assert.ok(!diagnostics.screenLocked, "Native input tests require an unlocked macOS session");
assert.ok(diagnostics.accessibility && diagnostics.screenRecording, "Native input tests require Accessibility and Screen Recording permissions");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "cua-input-"));
const app = path.join(temp, "CUAInputFixture.app");
const macos = path.join(app, "Contents/MacOS");
fs.mkdirSync(macos, { recursive: true });
const binary = path.join(macos, "CUAInputFixture");
const bundle = uniqueFixtureBundle("test.acua.input-fixture");
fs.writeFileSync(path.join(app, "Contents/Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>CUAInputFixture</string><key>CFBundleName</key><string>CUAInputFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync("swiftc", ["-parse-as-library", "-module-cache-path", "/private/tmp/cua-swift-module-cache", path.join(root, "test/InputFixture.swift"), "-o", binary], { stdio: "inherit" });
execFileSync("codesign", ["--force", "--sign", "-", app], { stdio: "inherit" });
const fixture = spawn(binary, [temp], { stdio: ["ignore", "ignore", "pipe"] });
fixture.stderr.on("data", data => process.stderr.write(data));
const socket = path.join(temp, "service.sock");
const screenshotDirectory = path.join(temp, "screenshots");
const service = spawn(serviceTestExecutable(root), [socket], { env: serviceTestEnvironment({ ...process.env, CODEX_HOME: temp, ACUA_DIAGNOSTICS: "1", ACUA_SCREENSHOT_DIRECTORY: screenshotDirectory }), stdio: ["ignore", "ignore", "pipe"] });
service.stderr.on("data", data => process.stderr.write(data));
const events = () => {
  try { return fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse); }
  catch { return []; }
};
async function until(fn, label, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const value = fn(); if (value) return value; await new Promise(r => setTimeout(r, 20)); }
  throw new Error(`Timeout: ${label}; artifacts ${temp}`);
}
async function command(value, expected = value) {
  const before = events().length;
  publishFixtureCommand(path.join(temp, "command"), value);
  return until(() => events().slice(before).find(e => e.event === expected), value);
}
globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket }, requestMeta: {},
  nativePipe: { createConnection: p => new Promise((resolve, reject) => {
    const stream = net.createConnection({ path: p });
    stream.once("connect", () => resolve(stream)); stream.once("error", reject);
  }) },
};
const { MacComputerUseClient } = await import("./support/js-client/client.js");
const client = new MacComputerUseClient();
const control = new MacComputerUseClient();
const pass = name => console.log(`PASS ${name}`);
try {
  await until(() => fs.existsSync(socket) && events().find(e => e.event === "ready"), "fixture and service ready");
  const state = await client.getAppState(bundle);
  assert.equal(state.app.pid, fixture.pid);
  assert.equal(state.app.bundleIdentifier, bundle);
  assert.equal(typeof state.app.appPath, "string");
  fs.writeFileSync(path.join(temp, "initial-ax.txt"), state.appSnapshot.text);
  const ids = [...state.appSnapshot.text.matchAll(/^\s*(\d+)\s/gm)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length, "multiwindow snapshot repeats earlier nodes");
  assert.equal([...state.appSnapshot.text.matchAll(/^\s*\d+ standard window CUA input target/gm)].length, 1);
  assert.ok(!state.appSnapshot.text.includes('CUA input decoy'));
  pass("native snapshot describes the selected target window with unique node IDs");
  const find = id => {
    const line = state.appSnapshot.text.split("\n").find(line => line.includes(id));
    assert.ok(line, `missing accessibility element ${id}`);
    return Number(line.match(/^\s*(\d+)\s/)[1]);
  };
  const editor = find("input-editor");
  let button = find("input-button");
  await assert.rejects(client.setValue({ app: bundle, elementIndex: 99999, value: "must not write" }), error => error.code === -10008);
  pass("unknown element ID fails after a real observation without changing a control");
  await client.click({ app: bundle, elementIndex: button });
  const animationStart = events().length;
  await command("animate-title", "animation-started");
  const settlingStart = Date.now();
  const settled = await client.getAppState({ app: bundle, disableDiff: true });
  assert.ok(events().slice(animationStart).some(event => event.event === "animation-ended"), "capture returned while title changes were still arriving");
  assert.ok(Date.now() - settlingStart >= 300, "settling did not follow title-change notifications");
  assert.ok(settled.appSnapshot.text.includes('CUA input target'));
  pass("capture waits for real AX title-change notifications to become quiet");
  const initial = (await command("state")).text;
  const expected = initial.indexOf("segundo alvo") + "segundo ".length;
  await client.selectText({ app: bundle, elementIndex: editor, text: "alvo", prefix: "segundo ", suffix: " fim" });
  let actual = await command("state");
  assert.equal(actual.text, initial);
  assert.deepEqual(actual.selection, [expected, 4]);
  pass("selection changes only the range, preserving the document and Unicode offsets");
  await client.selectText({ app: bundle, elementIndex: editor, text: "alvo", prefix: "segundo ", selection: "cursor_after" });
  assert.deepEqual((await command("state")).selection, [expected + 4, 0]);
  await client.selectText({ app: bundle, elementIndex: editor, text: "café" });
  assert.equal((await command("state")).selection[1], 5);
  pass("cursor-after and decomposed accents use the actual source range");
  await client.setValue({ app: bundle, elementIndex: editor, value: "e\u0301text étext" });
  await client.getAppState({ app: bundle, disableDiff: true });
  await client.selectText({ app: bundle, elementIndex: editor, text: "text", prefix: "é" });
  actual = await command("state");
  assert.equal(actual.text, "e\u0301text étext");
  assert.deepEqual(actual.selection, [8, 4]);
  pass("native context selects the composed occurrence by its UTF-16 length");
  await client.setValue({ app: target, elementIndex: editor, value: "e\u0301text" });
  await client.getAppState({ app: target, disableDiff: true });
  const beforeContextRejection = await command("state");
  await assert.rejects(client.selectText({ app: bundle, elementIndex: editor, text: "text", prefix: "é" }),
    error => error.code === -10008);
  actual = await command("state");
  assert.equal(actual.text, beforeContextRejection.text);
  assert.deepEqual(actual.selection, beforeContextRejection.selection);
  await client.selectText({ app: bundle, elementIndex: editor, text: "text", prefix: "\u0301" });
  assert.deepEqual((await command("state")).selection, [2, 4]);
  pass("native UTF-16 context rejects a length mismatch and accepts the actual combining unit");
  await client.setValue({ app: bundle, elementIndex: editor, value: "x\r\ntext" });
  await client.getAppState({ app: bundle, disableDiff: true });
  await client.selectText({ app: bundle, elementIndex: editor, text: "text", prefix: "\n" });
  actual = await command("state");
  assert.equal(actual.text, "x\r\ntext");
  assert.deepEqual(actual.selection, [3, 4]);
  pass("native selection uses the last UTF-16 unit of CRLF context");
  await client.setValue({ app: bundle, elementIndex: editor, value: "texté" });
  await client.getAppState({ app: bundle, disableDiff: true });
  const beforeSuffixRejection = await command("state");
  await assert.rejects(client.selectText({ app: bundle, elementIndex: editor, text: "text", suffix: "e\u0301" }),
    error => error.code === -10008);
  actual = await command("state");
  assert.equal(actual.text, beforeSuffixRejection.text);
  assert.deepEqual(actual.selection, beforeSuffixRejection.selection);
  await client.setValue({ app: bundle, elementIndex: editor, value: initial });
  await client.getAppState({ app: bundle, disableDiff: true });
  await client.selectText({ app: bundle, elementIndex: editor, text: "café" });
  pass("native suffix rejection preserves selection and document content");
  const unchanged = await command("state");
  for (const text of ["alvo", "not in the document"]) {
    await assert.rejects(client.selectText({ app: bundle, elementIndex: editor, text }), e => e.code === -10008);
    const current = await command("state");
    assert.equal(current.text, unchanged.text); assert.deepEqual(current.selection, unchanged.selection);
  }
  pass("ambiguous and missing text fail without modifying content or selection");
  await client.selectText({ app: bundle, elementIndex: editor, text: "👩🏽‍💻", selection: "cursor_after" });
  await command("focus-decoy", "decoy-focused");
  await client.typeText({ app: bundle, text: " / escrito 🙂" });
  await client.getAppState({ app: bundle, disableDiff: true });
  actual = await command("state");
  assert.equal(actual.text, initial + " / escrito 🙂");
  assert.equal(actual.decoy, "DO NOT TOUCH");
  pass("Unicode typing goes to the requested window after a decoy takes focus");
  await command("deactivate", "deactivated");
  await client.pressKey({ app: bundle, key: "Super_L+a" });
  actual = await command("state");
  assert.deepEqual(actual.selection, [0, actual.text.length]);
  assert.equal(actual.decoy, "DO NOT TOUCH");
  pass("keyboard shortcut restores the requested app/window after deactivation");
  let before = events().length;
  await client.click({ app: bundle, elementIndex: button, clickCount: 2 });
  await until(() => events().slice(before).filter(e => e.event === "input" && e.type === 1).length >= 2, "two mouse-downs");
  let input = events().slice(before).filter(e => e.event === "input" && e.type === 1);
  assert.deepEqual(input.map(e => e.clickCount), [1, 2]);
  pass("double-click on an AXPress button remains a real double-click");
  before = events().length;
  await client.click({ app: bundle, elementIndex: button, mouseButton: "right" });
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 3), "right mouse-down");
  assert.equal(events().slice(before).filter(e => e.event === "button-action").length, 0);
  pass("right-click does not turn into AXPress");
  before = events().length;
  await client.click({ app: bundle, elementIndex: button, key: "Shift", duration: 0.16 });
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "held mouse-up");
  input = events().slice(before).filter(e => e.event === "input");
  const down = input.find(e => e.type === 1), up = input.find(e => e.type === 2);
  assert.ok(down.flags & 0x20000); assert.ok(up.flags & 0x20000);
  assert.ok(up.timestamp - down.timestamp >= 0.13);
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "modifier release");
  pass("held Shift-click preserves flags, duration and key release");
  before = events().length;
  const expiring = client.click({ app: bundle, elementIndex: button, key: "Shift", duration: 1 }, { timeoutSeconds: 0.6 })
    .then(() => ({ ok: true }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "expired click starts before deadline");
  assert.ok((await expiring).error, "held click should expire");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "expired click releases mouse");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "expired click releases shift");
  await client.listApps();
  pass("deadline expiry releases held mouse/key and leaves the connection usable");
  before = events().length;
  const replacement = await command("replace-button", "button-replaced");
  // The fixture keeps the removed button alive, so AX never reports it
  // destroyed and refetch (ControllerElementRefetch.resolve) does not run.
  // The stale element lists no AX action, so the click takes the pointer path
  // at its old frame, where nothing is left. It must never press the detached
  // object; a fresh get_app_state publishes the replacement under a new ID.
  await client.click({ app: target, elementIndex: button });
  await new Promise(resolve => setTimeout(resolve, 300));
  assert.ok(!events().slice(before).some(e => e.event === "button-action"), "a stale ID does not press the detached button");
  const afterReplacement = await client.getAppState({ app: target, disableDiff: true });
  const replacementLine = afterReplacement.appSnapshot.text.split("\n").find(line => line.includes("input-button"));
  assert.ok(replacementLine, "the replacement button is published");
  await client.click({ app: target, elementIndex: Number(replacementLine.match(/^\s*(\d+)\s/)[1]) });
  const pressed = await until(() => events().slice(before).find(e => e.event === "button-action"), "replacement button action");
  assert.equal(pressed.generation, replacement.generation);
  assert.equal(pressed.attached, true);
  pass("a stale ID never presses the detached button; a fresh capture's ID presses the replacement");
  await command("insert-button", "button-inserted");
  const diff = await client.getAppState(target);
  assert.match(diff.appSnapshot.text, /extra-button/);
  const full = await client.getAppState({ app: target, disableDiff: true });
  const observedId = id => Number(full.appSnapshot.text.split("\n").find(line => line.includes(id)).match(/^\s*(\d+)\s/)[1]);
  assert.notEqual(observedId("input-button"), button, "replacement receives a fresh published native ID");
  button = observedId("input-button");
  assert.equal(observedId("input-editor"), editor);
  assert.ok(full.appSnapshot.text.includes("extra-button"));
  pass("insertion is published, the unchanged editor keeps its ID and the replacement gets a fresh native ID");
  // AX diffs ("no_change") are only produced for the node_repl client
  // (ControllerRequestConfiguration); a socket client gets the full tree again.
  const unchangedTree = await client.getAppState(target);
  assert.equal(unchangedTree.appSnapshot.text, full.appSnapshot.text);
  const offscreen = observedId("offscreen-button");
  before = events().length;
  await client.click({ app: bundle, elementIndex: offscreen, duration: 0.03 });
  await until(() => events().slice(before).find(e => e.event === "target-revealed"), "offscreen control scrolled into view");
  const offscreenAction = await until(() => events().slice(before).find(e => e.event === "button-action" && e.generation === 100), "mouse click on revealed control");
  assert.equal(offscreenAction.attached, true);
  pass("offscreen control is revealed before a real pointer click is delivered");
  const concurrent = await Promise.all([client.getAppState(bundle), control.getAppState(bundle)]);
  for (const observed of concurrent) {
    assert.match(observed.appSnapshot.screenshot.url, /^file:\/\//);
    assert.equal(observed.appSnapshot.screenshot.mimeType, 'image/jpeg');
    assert.ok(fs.readFileSync(new URL(observed.appSnapshot.screenshot.url)).subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff])));
  }
  const deliveredImages = [state, settled, diff, full, unchangedTree, ...concurrent].map(value => new URL(value.appSnapshot.screenshot.url));
  for (const file of deliveredImages) assert.ok(fs.existsSync(file), "delivered capture remains readable throughout the session");
  pass("concurrent captures and earlier delivered image files remain readable until session teardown");
  before = events().length;
  const interrupted = client.click({ app: bundle, elementIndex: offscreen, key: "Shift", duration: 1 })
    .then(value => ({ value }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "mouse held before external event");
  await command("external-intervention");
  assert.equal((await interrupted).error?.code, -10016, "external event must cancel held input through the actual event tap");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "intervention releases held mouse");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "intervention releases modifier");
  await assert.rejects(control.typeText({ app: bundle, text: "must not type after intervention" }), error => error.code === -10016);
  await new Promise(resolve => setTimeout(resolve, 5100));
  await assert.rejects(control.typeText({ app: bundle, text: "must still require requery" }), error => error.code === -10016);
  await control.getAppState(bundle);
  await client.click({ app: bundle, elementIndex: offscreen, duration: 0.03 });
  pass("external process event interrupts held input, releases mouse/key, and requires quiet state requery before recovery");
  await command("ambiguous-button", "button-ambiguous");
  before = events().length;
  await assert.rejects(client.click({ app: bundle, elementIndex: button }), error => error.code === -10008);
  assert.equal(events().slice(before).filter(e => e.event === "button-action").length, 0);
  pass("ambiguous duplicate controls are rejected before a button action");
  before = events().length;
  const running = client.click({ app: bundle, elementIndex: offscreen, key: "Shift", duration: 1 })
    .then(value => ({ value }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "mouse held before stop");
  const stopped = await control.stopApp(bundle);
  assert.equal(stopped.active, false);
  assert.equal(stopped.currentApp.pid, fixture.pid);
  assert.equal((await running).error?.code, -10012);
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "stop releases held mouse");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "stop releases modifier");
  assert.equal(fixture.exitCode, null);
  for (const file of deliveredImages) assert.ok(!fs.existsSync(file), "session teardown removes its delivered images");
  await assert.rejects(client.startApp(bundle), error => error.code === -10012);
  await assert.rejects(client.getAppState(bundle), error => error.code === -10012);
  pass("stop on another connection cancels held input, releases state/files, and leaves the app running");
  console.log(`ALL INPUT INTEGRATION CHECKS PASSED — artifacts: ${temp}`);
} finally {
  for (const connection of [client, control]) {
    for (const transport of connection.transports.values()) { try { (await transport).close(); } catch {} }
  }
  service.kill("SIGTERM"); fixture.kill("SIGTERM");
}
