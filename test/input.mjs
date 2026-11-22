import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
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
const target = fixtureAppTarget(app);
const fixture = spawn(binary, [temp], { stdio: ["ignore", "ignore", "pipe"] });
fixture.stderr.on("data", data => process.stderr.write(data));
const socket = path.join(temp, "service.sock");
const screenshotDirectory = path.join(temp, "screenshots");
// The service creates only numbered collision folders, never this base folder.
fs.mkdirSync(screenshotDirectory, { recursive: true });
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
  const state = await client.getAppState(target);
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
  // The native service reports a missing ID as a generic server error (-10005).
  await assert.rejects(client.setValue({ app: target, elementIndex: 99999, value: "must not write" }),
    error => error.code === -10005 && error.message.includes("99999 is an invalid element ID"));
  pass("unknown element ID fails after a real observation without changing a control");
  await client.click({ app: target, elementIndex: button });
  const animationStart = events().length;
  await command("animate-title", "animation-started");
  const settlingStart = Date.now();
  // The native service settles inside an action that returns its own
  // appSnapshot, when the click operation finishes. A later
  // get_app_state only settles after an action that deferred its appSnapshot.
  await client.click({ app: target, elementIndex: button });
  assert.ok(events().slice(animationStart).some(event => event.event === "animation-ended"), "the click returned while title changes were still arriving");
  const settled = await client.getAppState({ app: target, disableDiff: true });
  assert.ok(Date.now() - settlingStart >= 300, "settling did not follow title-change notifications");
  assert.ok(settled.appSnapshot.text.includes('CUA input target'));
  pass("an action's capture waits for real AX title-change notifications to become quiet");
  const initial = (await command("state")).text;
  const expected = initial.indexOf("segundo alvo") + "segundo ".length;
  await client.selectText({ app: target, elementIndex: editor, text: "alvo", prefix: "segundo ", suffix: " fim" });
  let actual = await command("state");
  assert.equal(actual.text, initial);
  assert.deepEqual(actual.selection, [expected, 4]);
  pass("selection changes only the range, preserving the document and Unicode offsets");
  await client.selectText({ app: target, elementIndex: editor, text: "alvo", prefix: "segundo ", selection: "cursor_after" });
  assert.deepEqual((await command("state")).selection, [expected + 4, 0]);
  await client.selectText({ app: target, elementIndex: editor, text: "café" });
  assert.equal((await command("state")).selection[1], 5);
  pass("cursor-after and decomposed accents use the actual source range");
  await client.setValue({ app: target, elementIndex: editor, value: "e\u0301text étext" });
  await client.getAppState({ app: target, disableDiff: true });
  await client.selectText({ app: target, elementIndex: editor, text: "text", prefix: "é" });
  actual = await command("state");
  assert.equal(actual.text, "e\u0301text étext");
  assert.deepEqual(actual.selection, [8, 4]);
  pass("native context selects the composed occurrence by its UTF-16 length");
  await client.setValue({ app: target, elementIndex: editor, value: "e\u0301text" });
  await client.getAppState({ app: target, disableDiff: true });
  const beforeContextRejection = await command("state");
  // The native service reports an unavailable source range as a generic server error (-10005).
  await assert.rejects(client.selectText({ app: target, elementIndex: editor, text: "text", prefix: "é" }),
    error => error.code === -10005 && error.message.includes("sourceRangeUnavailable"));
  actual = await command("state");
  assert.equal(actual.text, beforeContextRejection.text);
  assert.deepEqual(actual.selection, beforeContextRejection.selection);
  await client.selectText({ app: target, elementIndex: editor, text: "text", prefix: "\u0301" });
  assert.deepEqual((await command("state")).selection, [2, 4]);
  pass("native UTF-16 context rejects a length mismatch and accepts the actual combining unit");
  await client.setValue({ app: target, elementIndex: editor, value: "x\r\ntext" });
  await client.getAppState({ app: target, disableDiff: true });
  await client.selectText({ app: target, elementIndex: editor, text: "text", prefix: "\n" });
  actual = await command("state");
  assert.equal(actual.text, "x\r\ntext");
  assert.deepEqual(actual.selection, [3, 4]);
  pass("native selection uses the last UTF-16 unit of CRLF context");
  await client.setValue({ app: target, elementIndex: editor, value: "texté" });
  await client.getAppState({ app: target, disableDiff: true });
  const beforeSuffixRejection = await command("state");
  // The native service reports an unavailable source range as a generic server error (-10005).
  await assert.rejects(client.selectText({ app: target, elementIndex: editor, text: "text", suffix: "e\u0301" }),
    error => error.code === -10005 && error.message.includes("sourceRangeUnavailable"));
  actual = await command("state");
  assert.equal(actual.text, beforeSuffixRejection.text);
  assert.deepEqual(actual.selection, beforeSuffixRejection.selection);
  await client.setValue({ app: target, elementIndex: editor, value: initial });
  await client.getAppState({ app: target, disableDiff: true });
  await client.selectText({ app: target, elementIndex: editor, text: "café" });
  pass("native suffix rejection preserves selection and document content");
  const unchanged = await command("state");
  for (const text of ["alvo", "not in the document"]) {
    await assert.rejects(client.selectText({ app: target, elementIndex: editor, text }),
      e => e.code === -10005 && e.message.includes("sourceRangeUnavailable"));
    const current = await command("state");
    assert.equal(current.text, unchanged.text); assert.deepEqual(current.selection, unchanged.selection);
  }
  pass("ambiguous and missing text fail without modifying content or selection");
  await client.selectText({ app: target, elementIndex: editor, text: "👩🏽‍💻", selection: "cursor_after" });
  await command("focus-decoy", "decoy-focused");
  // type_text posts keys to the app's process and only enforces app-level
  // focus (keyboard operation and synthetic focus).
  // It does not retarget the element last touched, so while the app stays
  // active the text lands wherever the app's own keyboard focus is.
  await client.typeText({ app: target, text: " / escrito 🙂" });
  await client.getAppState({ app: target, disableDiff: true });
  actual = await command("state");
  assert.equal(actual.text, initial);
  const decoyText = "DO NOT TOUCH / escrito 🙂";
  assert.equal(actual.decoy, decoyText);
  pass("Unicode typing follows the app's own keyboard focus into the decoy window");
  // No action moves an app's keyboard focus to another of its windows: an
  // element click does not make a background window key. The app (here the
  // fixture) returns focus to the editor's window, and typing follows it.
  await command("request-key-focus", "requested-key-focus");
  const refocused = await client.getAppState({ app: target, disableDiff: true });
  const editorLine = refocused.appSnapshot.text.split("\n").find(line => line.includes("input-editor"));
  assert.ok(editorLine, "the editor's window is captured again once the app focuses it");
  const refocusedEditor = Number(editorLine.match(/^\s*(\d+)\s/)[1]);
  await client.selectText({ app: target, elementIndex: refocusedEditor, text: "👩🏽‍💻", selection: "cursor_after" });
  await client.typeText({ app: target, text: " / escrito 🙂" });
  await client.getAppState({ app: target, disableDiff: true });
  actual = await command("state");
  assert.equal(actual.text, initial + " / escrito 🙂");
  assert.equal(actual.decoy, decoyText);
  pass("once the app focuses the editor again, Unicode typing reaches it and leaves the decoy alone");
  await command("deactivate", "deactivated");
  await client.pressKey({ app: target, key: "Super_L+a" });
  actual = await command("state");
  assert.deepEqual(actual.selection, [0, actual.text.length]);
  assert.equal(actual.decoy, decoyText);
  pass("keyboard shortcut reaches the focused editor after the app deactivates itself");
  // ControllerLowerClick uses AXPress only for a single plain left click, so a
  // double-click on an AXPress button is delivered as real mouse events.
  let before = events().length;
  await client.click({ app: target, elementIndex: button, clickCount: 2 });
  await until(() => events().slice(before).filter(e => e.event === "input" && e.type === 1).length >= 2, "two mouse-downs");
  let input = events().slice(before).filter(e => e.event === "input" && e.type === 1);
  assert.deepEqual(input.map(e => e.clickCount), [1, 2]);
  pass("double-click on an AXPress button remains a real double-click");
  before = events().length;
  await client.click({ app: target, elementIndex: button, mouseButton: "right" });
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 3), "right mouse-down");
  assert.equal(events().slice(before).filter(e => e.event === "button-action").length, 0);
  pass("right-click does not turn into AXPress");
  before = events().length;
  await client.click({ app: target, elementIndex: button, key: "Shift_L", duration: 0.16 });
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "held mouse-up");
  input = events().slice(before).filter(e => e.event === "input");
  const down = input.find(e => e.type === 1), up = input.find(e => e.type === 2);
  assert.ok(down.flags & 0x20000); assert.ok(up.flags & 0x20000);
  assert.ok(up.timestamp - down.timestamp >= 0.13);
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "modifier release");
  pass("held Shift-click preserves flags, duration and key release");
  before = events().length;
  const expiring = client.click({ app: target, elementIndex: button, key: "Shift_L", duration: 1 }, { timeoutSeconds: 0.6 })
    .then(() => ({ ok: true }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "expired click starts before deadline");
  assert.ok((await expiring).error, "held click request should expire for the caller");
  // Expiry abandons only the caller's wait. The queued job is an unstructured
  // task (ControllerInstanceSerialExecutor) and the hold interval ignores
  // cancellation (ControllerClickEventSender), so the full hold still runs.
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "expired click releases mouse");
  input = events().slice(before).filter(e => e.event === "input");
  const expiredDown = input.find(e => e.type === 1), expiredUp = input.find(e => e.type === 2);
  assert.ok(expiredUp.timestamp - expiredDown.timestamp >= 0.9, "an expired request does not cut its held click short");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "expired click releases shift");
  await client.listApps();
  pass("deadline expiry ends the caller's wait while the held click completes and releases mouse/key; the client stays usable");
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
  await client.click({ app: target, elementIndex: offscreen, duration: 0.03 });
  await until(() => events().slice(before).find(e => e.event === "target-revealed"), "offscreen control scrolled into view");
  const offscreenAction = await until(() => events().slice(before).find(e => e.event === "button-action" && e.generation === 100), "mouse click on revealed control");
  assert.equal(offscreenAction.attached, true);
  pass("offscreen control is revealed before a real pointer click is delivered");
  const concurrent = await Promise.all([client.getAppState(target), control.getAppState(target)]);
  for (const observed of concurrent) {
    assert.match(observed.appSnapshot.screenshot.url, /^file:\/\//);
    assert.equal(observed.appSnapshot.screenshot.mimeType, 'image/jpeg');
    assert.ok(fs.readFileSync(new URL(observed.appSnapshot.screenshot.url)).subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff])));
  }
  const deliveredImages = [state, settled, diff, full, unchangedTree, ...concurrent].map(value => new URL(value.appSnapshot.screenshot.url));
  for (const file of deliveredImages) assert.ok(fs.existsSync(file), "delivered capture remains readable throughout the session");
  pass("concurrent captures and earlier delivered image files remain readable until session teardown");
  before = events().length;
  const interrupted = client.click({ app: target, elementIndex: offscreen, key: "Shift_L", duration: 1 })
    .then(value => ({ value }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "mouse held before external event");
  const intervention = await command("external-intervention");
  // Input that is already held finishes (nothing observes the interruption
  // notification). The intervention gates the next request instead, through
  // intervention admission.
  const interruptedOutcome = await interrupted;
  assert.equal(interruptedOutcome.error, undefined, `held click completes across an intervention: ${interruptedOutcome.error?.message}`);
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "held click releases mouse after intervention");
  input = events().slice(before).filter(e => e.event === "input");
  const interruptedDown = input.find(e => e.type === 1), interruptedUp = input.find(e => e.type === 2);
  assert.ok(interruptedUp.timestamp - interruptedDown.timestamp >= 0.9, "an intervention does not cut the held click short");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "held click releases modifier after intervention");
  pass("external process event seen by the real event tap does not cancel held input already running");
  const beforeRefusal = await command("state");
  // The next action first waits out the 5 s debounce (manager deadline), then
  // is refused until get_app_state, because it does not allow a state requery.
  await assert.rejects(control.typeText({ app: target, text: "must not type after intervention" }),
    error => error.code === -10016 && error.message.includes("Re-query the latest state"));
  assert.ok(Date.now() / 1000 - intervention.postedAt >= 4.5, "the next action waits out the intervention debounce");
  await assert.rejects(control.typeText({ app: target, text: "must still require requery" }),
    error => error.code === -10016 && error.message.includes("Re-query the latest state"));
  actual = await command("state");
  assert.equal(actual.text, beforeRefusal.text);
  assert.equal(actual.decoy, beforeRefusal.decoy);
  await control.getAppState(target);
  await client.click({ app: target, elementIndex: offscreen, duration: 0.03 });
  pass("after an intervention the next actions wait out the debounce, type nothing, and recover only after a state requery");
  await command("ambiguous-button", "button-ambiguous");
  before = events().length;
  // An ambiguous refetch is reported as a generic server error with this text.
  await assert.rejects(client.click({ app: target, elementIndex: button }),
    error => error.code === -10005 && error.message.includes("multiple elements were found that match the criteria"));
  assert.equal(events().slice(before).filter(e => e.event === "button-action").length, 0);
  pass("ambiguous duplicate controls are rejected before a button action");
  before = events().length;
  const running = client.click({ app: target, elementIndex: offscreen, key: "Shift_L", duration: 1 })
    .then(value => ({ value }), error => ({ error }));
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 1), "mouse held before stop");
  // Stop records the raw identifier as received, so it names the
  // canonical target that keys the instance; a bundle ID would find none.
  // It marks the stop at once, but deactivates on the instance queue after
  // the held click finishes.
  const stopped = await control.stopApp(target);
  assert.equal(stopped.active, false);
  assert.equal(stopped.currentApp.pid, fixture.pid);
  const runningOutcome = await running;
  assert.equal(runningOutcome.error, undefined, `held click admitted before Stop completes: ${runningOutcome.error?.message}`);
  assert.equal(runningOutcome.value.app.pid, fixture.pid);
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 2), "held click releases mouse before stop teardown");
  await until(() => events().slice(before).some(e => e.event === "input" && e.type === 12 && !(e.flags & 0x20000)), "held click releases modifier before stop teardown");
  assert.equal(fixture.exitCode, null);
  for (const file of deliveredImages) assert.ok(!fs.existsSync(file), "session teardown removes its delivered images");
  // Launch preparation precedes the stopped check, so start and
  // state requests on the running fixture reach it and report the stop.
  await assert.rejects(client.startApp(target), error => error.code === -10012);
  await assert.rejects(client.getAppState(target), error => error.code === -10012);
  await assert.rejects(client.click({ app: target, elementIndex: offscreen }), error => error.code === -10012);
  pass("stop on another connection lets admitted held input finish, then releases state/files, refuses later requests, and leaves the app running");
  console.log(`ALL INPUT INTEGRATION CHECKS PASSED — artifacts: ${temp}`);
} finally {
  for (const connection of [client, control]) {
    for (const transport of connection.transports.values()) { try { (await transport).close(); } catch {} }
  }
  service.kill("SIGTERM"); fixture.kill("SIGTERM");
}
