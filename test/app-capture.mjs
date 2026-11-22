import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
// Actual Start/Next native capture through the shipped client wrapper and socket.
// Runs only a disposable fixture; it does not capture arbitrary user windows.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const serviceBin = serviceTestExecutable(root);
const diagnostic = JSON.parse(execFileSync(serviceBin, ["--diagnostics"], { encoding: "utf8" }));
assert.ok(!diagnostic.screenLocked && diagnostic.accessibility && diagnostic.screenRecording, "Native app capture requires an unlocked session and granted permissions");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "cua-app-capture-"));
const app = path.join(temp, "CUACoordinateFixture.app"), macos = path.join(app, "Contents/MacOS");
fs.mkdirSync(macos, { recursive: true });
const fixture = path.join(macos, "CUACoordinateFixture");
const bundle = uniqueFixtureBundle("test.acua.coordinate-fixture");
fs.writeFileSync(path.join(app, "Contents/Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>CUACoordinateFixture</string><key>CFBundleName</key><string>CUACoordinateFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync("swiftc", ["-parse-as-library", "-module-cache-path", "/private/tmp/cua-swift-module-cache", path.join(root, "test/CoordinateFixture.swift"), "-o", fixture], { stdio: "inherit" });
const target = fixtureAppTarget(app);
let fixtureProcess, service, client;
const files = new Set();
const captureDirectory = path.join(temp, "captures");
async function until(fn, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) { if (await fn()) return; await new Promise(resolve => setTimeout(resolve, 40)); }
  throw new Error(`Timeout: ${label}`);
}
globalThis.nodeRepl = {
  env: process.env, requestMeta: {},
  nativePipe: { createConnection: socketPath => new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    socket.once("connect", () => resolve(socket)); socket.once("error", reject);
  }) },
};
let passed = 0;
function check(name, condition) { assert.ok(condition, name); passed++; console.log(`PASS ${name}`); }
try {
  fixtureProcess = spawn(fixture, [temp], { stdio: ["ignore", "ignore", "pipe"] });
  fixtureProcess.stderr.on("data", data => process.stderr.write(data));
  await until(() => fs.existsSync(path.join(temp, "events.jsonl")) && fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").includes('"ready"'), "fixture ready");
  const socket = path.join(temp, "capture.sock");
  service = spawn(serviceBin, [socket], { env: serviceTestEnvironment({ ...process.env, ACUA_DIAGNOSTICS: "1", ACUA_SCREENSHOT_DIRECTORY: captureDirectory }), stdio: ["ignore", "ignore", "pipe"] });
  service.stderr.on("data", data => process.stderr.write(data));
  await until(() => fs.existsSync(socket), "service socket");
  nodeRepl.env = { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket };
  const { MacComputerUseClient } = await import("./support/js-client/client.js");
  client = new MacComputerUseClient({ timeoutSeconds: 45 });
  await assert.rejects(client.nextAppCaptureUpdate("missing"), e => e.code === -10005);
  passed++; console.log("PASS missing capture fails without waiting indefinitely");
  const collect = async requestID => {
    const updates = [];
    for (let i = 0; i < 8; i++) {
      const update = await client.nextAppCaptureUpdate(requestID);
      updates.push(update);
      assert.notEqual(update.type, "failed", `Native capture failed: ${JSON.stringify(update)}`);
      if (update.screenshot?.url) files.add(fileURLToPath(update.screenshot.url));
      if (update.type === "completed") break;
    }
    return updates;
  };
  for (const invalid of ["destination", "display-bounds", "display-scale"]) {
    const requestID = `invalid-animation-${invalid}`;
    const animationTarget = {
      destinationFrame: { x: 20, y: 20, width: 200, height: 100 },
      agentDisplay: { id: 1, bounds: { x: 0, y: 0, width: 1000, height: 800 },
        workArea: { x: 0, y: 25, width: 1000, height: 750 }, scaleFactor: 2 },
    };
    if (invalid === "destination") animationTarget.destinationFrame.width = 0;
    if (invalid === "display-bounds") animationTarget.agentDisplay.bounds.height = 0;
    if (invalid === "display-scale") animationTarget.agentDisplay.scaleFactor = 0;
    const response = await client.startAppCapture({ app: target, requestID, animationTarget, version: 1 });
    check(`${invalid}: invalid optional transition falls back to native capture`, response.result === "started" && response.animationDuration === undefined);
    const updates = await collect(requestID);
    check(`${invalid}: fallback retains the finite metadata/completed sequence`, updates[0]?.type === "metadata" && updates.at(-1)?.type === "completed");
    const screenshot = updates.find(update => update.screenshot)?.screenshot;
    const pixels = JSON.parse(execFileSync(fixture, ["--locate-image", fileURLToPath(screenshot.url)], { encoding: "utf8" }));
    check(`${invalid}: fallback delivers actual fixture screenshot pixels`, pixels.red && pixels.green && pixels.blue);
  }
  for (const version of [1, 2]) {
    const requestID = `native-${version}`;
    const response = await client.startAppCapture({ app: target, requestID, version });
    check(`v${version}: Start returns the native started contract`, response.result === "started");
    const updates = await collect(requestID);
    fs.writeFileSync(path.join(temp, `v${version}-updates.json`), JSON.stringify(updates, null, 2));
    check(`v${version}: metadata precedes content and completed is final`, updates[0]?.type === "metadata" && updates.at(-1)?.type === "completed");
    check(`v${version}: every stage identifies the same fixture app`, updates.every(u => u.app?.bundleIdentifier === bundle && u.app.pid > 0));
    const text = updates.find(u => u.type === "axText")?.text;
    check(`v${version}: actual AX content has no automation element IDs`, typeof text === "string" && text.includes("CUA coordinate target") && !text.includes("AXWindow") && !/^\s*(?:\[)?\d+\]?\s+standard window/m.test(text));
    const image = updates.find(u => u.screenshot)?.screenshot;
    check(`v${version}: screenshot contract carries native JPEG file`, image?.mimeType === "image/jpeg" && image.url.startsWith("file:"));
    const filename = fileURLToPath(image.url);
    const pixels = JSON.parse(execFileSync(fixture, ["--locate-image", filename], { encoding: "utf8" }));
    check(`v${version}: captured pixels contain all fixture targets`, pixels.red && pixels.green && pixels.blue);
    check(`v${version}: delivered file survives terminal consumption`, fs.existsSync(filename));
    if (version === 2) {
      const final = updates.at(-2);
      check("v2: reliable final-frame stage is delivered before completion", final.type === "screenshot" && !final.screenshot);
    }
    await assert.rejects(client.nextAppCaptureUpdate(requestID), e => e.code === -10005);
    passed++; console.log(`PASS v${version}: consumed capture is removed`);
  }
  const display = JSON.parse(execFileSync(fixture, ["--display-info"], { encoding: "utf8" })).displays[0];
  const overlayWindows = () => JSON.parse(execFileSync(fixture, ["--transition-windows", String(service.pid)], { encoding: "utf8" }));
  for (const version of [1, 2]) for (const presentationStyle of ["standard", "quick_chat"]) {
    const requestID = `transition-${version}-${presentationStyle}`;
    const work = display.workArea, width = Math.min(480, work.width * 0.5), height = Math.min(330, work.height * 0.5);
    const animationTarget = { destinationFrame: { x: work.x + (work.width - width) / 2, y: work.y + work.height * 0.2, width, height },
      destinationCornerRadius: 12, presentationStyle, agentDisplay: display };
    const response = await client.startAppCapture({ app: target, requestID, version, animationTarget });
    check(`${requestID}: native transition returns duration and spring metadata`, response.result === "started" && response.animationDuration > 0.9 && response.transitionSpringResponse >= 0.28 && response.transitionSpringDampingFraction === 0.73);
    check(`${requestID}: snapshot height follows the presentation style`, presentationStyle === "standard" ? response.transitionSnapshotHeight > height : response.transitionSnapshotHeight === Math.ceil(height));
    await until(() => overlayWindows().length > 0, "native overlay becomes onscreen");
    check(`${requestID}: transparent overlay is an actual level-25 WindowServer window`, overlayWindows().every(window => window.layer === 25));
    const updates = [];
    let finalFile, completed;
    for (let i = 0; i < 8; i++) {
      const update = await client.nextAppCaptureUpdate(requestID); updates.push(update);
      assert.notEqual(update.type, "failed", JSON.stringify(update));
      if (update.screenshot?.url) files.add(fileURLToPath(update.screenshot.url));
      if (update.transitionSnapshotURL) {
        finalFile = fileURLToPath(update.transitionSnapshotURL); files.add(finalFile);
        if (version === 2 && update.type === "screenshot") check(`${requestID}: final frame keeps overlay alive until terminal delivery`, overlayWindows().length > 0);
      }
      if (update.type === "completed") { completed = update; break; }
    }
    fs.writeFileSync(path.join(temp, `${requestID}-updates.json`), JSON.stringify(updates, null, 2));
    check(`${requestID}: completed carries a real final PNG`, completed?.transitionSnapshotURL?.startsWith("file:") && finalFile?.endsWith(".png") && fs.existsSync(finalFile));
    const pixels = JSON.parse(execFileSync(fixture, ["--locate-image", finalFile], { encoding: "utf8" }));
    check(`${requestID}: final transition contains actual captured fixture targets`, pixels.red && pixels.green && pixels.blue);
    const info = JSON.parse(execFileSync(fixture, ["--image-info", finalFile], { encoding: "utf8" }));
    fs.writeFileSync(path.join(temp, `${requestID}-image-info.json`), JSON.stringify(info));
    check(`${requestID}: final PNG preserves transparency`, info.alpha && info.transparent > 0 && info.opaque > 0);
    check(`${requestID}: final dimensions track destination and screen scale`, Math.abs(info.width - Math.round(width * display.scaleFactor)) <= 1 && Math.abs(info.height - Math.round(response.transitionSnapshotHeight * display.scaleFactor)) <= 2);
    if (version === 2) check(`${requestID}: reliable final frame precedes completion`, updates.at(-2)?.type === "screenshot" && updates.at(-2)?.transitionSnapshotURL === completed.transitionSnapshotURL);
    await until(() => overlayWindows().length === 0, "overlay cleanup after completion");
    check(`${requestID}: terminal delivery closes every overlay while retaining the PNG`, fs.existsSync(finalFile));
    fs.copyFileSync(finalFile, path.join(temp, `${requestID}.png`));
  }
  const stateForClick = await client.getAppState({ app: target, disableDiff: true });
  const clickImage = path.join(temp, "overlay-click-source.jpg");
  fs.writeFileSync(clickImage, fs.readFileSync(new URL(stateForClick.appSnapshot.screenshot.url)));
  const clickTargets = JSON.parse(execFileSync(fixture, ["--locate-image", clickImage], { encoding: "utf8" }));
  const clickRequestID = "overlay-does-not-intercept-input";
  const clickAnimation = { destinationFrame: { x: display.workArea.x + 100, y: display.workArea.y + 100, width: 450, height: 300 }, agentDisplay: display };
  await client.startAppCapture({ app: target, requestID: clickRequestID, version: 2, animationTarget: clickAnimation });
  await until(() => overlayWindows().length > 0, "overlay visible before source click");
  const beforeClick = fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").length;
  await client.click({ app: target, x: clickTargets.green[0], y: clickTargets.green[1] });
  await until(() => fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").slice(beforeClick).map(JSON.parse)
    .some(event => event.event === "down" && event.green), "source receives click while overlay is visible");
  const clickedEvents = fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").slice(beforeClick).map(JSON.parse);
  check("visible transition overlay does not intercept a real click on the source app", clickedEvents.some(event => event.event === "down" && event.green));
  check("source click does not prematurely complete the retained transition", overlayWindows().length > 0);
  const clickedCapture = await collect(clickRequestID);
  for (const update of clickedCapture) if (update.transitionSnapshotURL) files.add(fileURLToPath(update.transitionSnapshotURL));
  await until(() => overlayWindows().length === 0, "clicked transition completion removes overlay");
  check("capture and final frame complete after real input during the overlay", clickedCapture.at(-1)?.type === "completed" && !!clickedCapture.at(-1).transitionSnapshotURL);
  const failureTarget = { destinationFrame: { x: display.workArea.x + 100, y: display.workArea.y + 100, width: 450, height: 300 },
    presentationStyle: "standard", agentDisplay: display };
  const fixtureEvents = () => fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
  const command = async (value, event) => {
    const before = fixtureEvents().length; publishFixtureCommand(path.join(temp, "command"), value);
    await until(() => fixtureEvents().slice(before).some(item => item.event === event), `fixture ${value}`);
  };
  for (const failure of ["deadline", "replaced", "moved", "closed"]) {
    const requestID = `failure-${failure}`;
    const response = await client.startAppCapture({ app: target, requestID, version: 2, animationTarget: failureTarget },
      failure === "deadline" ? { timeoutSeconds: 0.5 } : {});
    assert.equal(response.result, "started");
    await until(() => overlayWindows().length > 0, "failure case overlay is onscreen");
    if (failure === "replaced") {
      await client.startAppCapture({ app: target, requestID, version: 2, animationTarget: failureTarget });
      check("reused capture ID removes its previous native overlay generation", overlayWindows().length === 1);
    }
    if (failure === "moved") await command("move", "moved");
    if (failure === "closed") await command("close", "closed");
    const updates = [];
    for (let i = 0; i < 8; i++) {
      const update = await client.nextAppCaptureUpdate(requestID); updates.push(update);
      if (update.screenshot?.url) files.add(fileURLToPath(update.screenshot.url));
      if (update.transitionSnapshotURL) files.add(fileURLToPath(update.transitionSnapshotURL));
      if (update.type === "completed" || update.type === "failed") break;
    }
    fs.writeFileSync(path.join(temp, `${requestID}-updates.json`), JSON.stringify(updates, null, 2));
    const end = updates.at(-1);
    if (failure === "replaced") check("late old producer does not corrupt the replacement transition", end?.type === "completed" && !!end.transitionSnapshotURL);
    else check(`${failure}: interrupted transition delivers terminal failure`, end?.type === "failed" && ["unknown_capture_failed", "screenshot_capture_failed"].includes(end.failureReason));
    await until(() => overlayWindows().length === 0, `${failure} removes all overlay windows`);
    check(`${failure}: native interruption leaves no visible overlay`, overlayWindows().length === 0);
    await assert.rejects(client.nextAppCaptureUpdate(requestID), error => error.code === -10005);
    passed++; console.log(`PASS ${failure}: consumed terminal capture is removed`);
    if (failure === "moved") { await command("restore", "restored"); await new Promise(resolve => setTimeout(resolve, 200)); }
  }
  console.log(`${passed} native app-capture checks passed; artifacts: ${temp}`);
} finally {
  if (client) for (const transport of client.transports.values()) (await transport).close?.();
  service?.kill("SIGTERM"); fixtureProcess?.kill("SIGTERM");
  for (const filename of files) fs.rmSync(filename, { force: true });
}
