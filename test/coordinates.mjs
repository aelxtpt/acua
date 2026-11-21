import { publishFixtureCommand } from './fixture-command.mjs';
import { serviceTestEnvironment, serviceTestExecutable, uniqueFixtureBundle, fixtureAppTarget } from './service-test-environment.mjs';
import { startNativeDesktop } from './native-desktop-service.mjs';
// Real pixels from a disposable app determine all pointer targets. No AXPress
// or coordinate-conversion code from the service is used to calculate them.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const diagnostics = JSON.parse(execFileSync(serviceTestExecutable(root), ["--diagnostics"], { encoding: "utf8" }));
assert.ok(!diagnostics.screenLocked, "Native coordinate tests require an unlocked macOS session");
assert.ok(diagnostics.accessibility && diagnostics.screenRecording, "Native coordinate tests require Accessibility and Screen Recording permissions");
const reviewSettings = Boolean(process.env.CUA_REVIEW_DESKTOP_LAUNCHER);
const settingsHarness = process.env.CUA_COORDINATE_SETTINGS_HARNESS || path.join(os.tmpdir(), "cua-coordinate-settings-harness", "AexComputerUseService");
if (!reviewSettings && !process.env.CUA_COORDINATE_SETTINGS_HARNESS) execFileSync("python3", [path.join(root, "test/build-native-automation-harness.py"), "--output", settingsHarness,
  "--swiftflags=-O -whole-module-optimization", "--native-settings-probe"], { stdio: "inherit" });
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "cua-coordinates-"));
const app = path.join(temp, "CUACoordinateFixture.app");
const bundle = uniqueFixtureBundle("test.acua.coordinate-fixture");
const macos = path.join(app, "Contents", "MacOS");
fs.mkdirSync(macos, { recursive: true });
const fixture = path.join(macos, "CUACoordinateFixture");
fs.writeFileSync(path.join(app, "Contents", "Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>CUACoordinateFixture</string><key>CFBundleName</key><string>CUACoordinateFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
execFileSync("swiftc", ["-parse-as-library", "-module-cache-path", "/private/tmp/cua-swift-module-cache", path.join(root, "test/CoordinateFixture.swift"), "-o", fixture], { stdio: "inherit" });
const fixtureProcess = spawn(fixture, [temp], { stdio: ["ignore", "ignore", "pipe"] });
fixtureProcess.stderr.on("data", data => process.stderr.write(data));
// Requests name the fixture by path; see fixtureAppTarget.
const fixtureApp = fixtureAppTarget(app);
const events = () => {
  try { return fs.readFileSync(path.join(temp, "events.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse); }
  catch { return []; }
};
async function until(fn, label, ms = 10000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 40)); }
  throw new Error(`Timeout: ${label}`);
}
async function command(value, expected) {
  const before = events().length;
  publishFixtureCommand(path.join(temp, "command"), value);
  return until(() => events().slice(before).find(e => e.event === expected), expected);
}
globalThis.nodeRepl = {
  env: process.env, requestMeta: {},
  nativePipe: { createConnection: p => new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: p });
    socket.once("connect", () => resolve(socket)); socket.once("error", reject);
  }) },
};
const { MacComputerUseClient } = await import("./support/js-client/client.js");
let service;
const report = message => console.log(`PASS ${message}`);
// Copies a capture next to the run artifacts and locates the fixture's markers in its pixels.
const locate = (url, name) => {
  const image = path.join(temp, `${name}.jpg`);
  fs.writeFileSync(image, fs.readFileSync(new URL(url)));
  return JSON.parse(execFileSync(fixture, ["--locate-image", image], { encoding: "utf8" }));
};
const sameMarkers = (actual, expected, message) => {
  assert.deepEqual(actual.__size, expected.__size, message);
  for (const key of ["red", "green", "blue"]) {
    for (let axis = 0; axis < 2; axis++) assert.ok(Math.abs(actual[key][axis] - expected[key][axis]) <= 3, message);
  }
};
try {
  const ready = await until(() => events().find(e => e.event === "ready"), "fixture ready");
  // "native" and "fit" run the real service with [screenshots].resolution:
  // "native" is every Retina pixel; "fit" is the ACUA default, a fitted,
  // point-normalized sizing.
  const realServiceSizing = { native: '[screenshots]\nresolution = "native"\nmax_image_bytes = 0\n', fit: "" };
  for (const sizing of ["points", "native", "fit", "legacy"]) {
    const socketName = `${sizing}.sock`;
    const socket = path.join(temp, socketName);
    const realService = sizing in realServiceSizing;
    const acuaHome = path.join(temp, `acua-${sizing}`);
    fs.mkdirSync(acuaHome, { recursive: true });
    fs.writeFileSync(path.join(acuaHome, "config.toml"), realServiceSizing[sizing] ?? "");
    if (reviewSettings && !realService) {
      ({ service } = startNativeDesktop(temp, bundle, fixtureApp, sizing, socketName));
    } else {
      service = spawn(realService ? serviceTestExecutable(root) : settingsHarness, [socket], {
        env: serviceTestEnvironment({ CODEX_HOME: path.join(temp, sizing), ACUA_HOME: acuaHome, CUA_OWNED_IMAGE_SIZING: sizing }),
        stdio: ["ignore", "ignore", "pipe"],
      });
      service.stderr.on("data", data => process.stderr.write(data));
    }
    await until(() => fs.existsSync(socket), "service socket");
    nodeRepl.env = { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: socket };
    const client = new MacComputerUseClient();
    // A fresh service has no controller for the app. Actions resolve the
    // instance with create: false, so only get_app_state opens one:
    // noInstance -> -10011 noActiveSession, before any coordinate mapping.
    await assert.rejects(client.click({ app: fixtureApp, x: 10, y: 10 }), e => e.code === -10011);
    report(`${sizing}: coordinate actions require a session opened by get_app_state`);
    const state = await client.getAppState(fixtureApp);
    const shot = state.appSnapshot;
    assert.ok(shot.screenshot?.url, "Screen Recording permission is required for coordinate integration tests");
    assert.equal(shot.coordinateSpace, undefined, "native wire has no coordinateSpace extension");
    assert.equal(shot.screenshot.mimeType, "image/jpeg");
    assert.ok(shot.screenshot.url.startsWith("file://"));
    const targets = locate(shot.screenshot.url, sizing);
    fs.writeFileSync(path.join(temp, `${sizing}-geometry.json`), JSON.stringify({ targets, ready }, null, 2));
    assert.ok(targets.red && targets.green && targets.blue, "all visual targets must be present in captured pixels");
    // Calibrate from the actual raster markers and the fixture's AppKit coordinates.
    const toPixel = ([x, y]) => [
      Math.round(targets.red[0] + (x - ready.redScreen[0]) * (targets.blue[0] - targets.red[0]) / (ready.blueScreen[0] - ready.redScreen[0])),
      Math.round(targets.red[1] + (y - ready.redScreen[1]) * (targets.blue[1] - targets.red[1]) / (ready.blueScreen[1] - ready.redScreen[1])),
    ];
    report(`${sizing}: captured focused window; ${targets.__size[0]}×${targets.__size[1]}, display scale ${ready.backingScale}`);
    if (sizing === "fit") {
      assert.ok(Math.max(...targets.__size) <= 2048 && Math.min(...targets.__size) <= 768, `fit image ${targets.__size} exceeds 2048x768`);
      report("fit: the default image is within 2048 on the long edge and 768 on the short edge");
    }
    await command("focus-decoy", "decoy-focused");
    let before = events().length;
    // Targeting delivers to the first window, front to back, that
    // contains the point. Once the decoy covers the captured window, the click
    // reaches the decoy rather than raising the window from the old screenshot.
    const covered = await client.click({ app: fixtureApp, x: targets.green[0], y: targets.green[1] });
    const coveredClick = await until(() => events().slice(before).find(e => e.event === "observed" && e.type === 1), "click reaches the front window");
    assert.notEqual(coveredClick.window, ready.smallWindowID, "a covered window does not receive the click");
    assert.ok(!events().slice(before).some(e => e.event === "down" && e.green), "the covered green target is not clicked");
    // Socket clients get a capture with every action reply, and that capture
    // re-reads the focused window, now the decoy (storing its frame and
    // scale). From here on, pixels map through the decoy capture.
    const decoyTargets = locate(covered.appSnapshot.screenshot.url, `${sizing}-decoy`);
    assert.notEqual(decoyTargets.__size[0], targets.__size[0], "the action reply captures the decoy, which is now focused");
    report(`${sizing}: a click at a covered point reaches the window in front`);
    await command("restore", "restored");
    // The old screenshot is no longer the coordinate space: re-read state once
    // the target window is focused again. Its pixels match the first capture.
    const restored = await client.getAppState(fixtureApp);
    sameMarkers(locate(restored.appSnapshot.screenshot.url, `${sizing}-restored`), targets,
      "the restored window captures with its earlier geometry");
    before = events().length;
    await client.click({ app: fixtureApp, x: targets.green[0], y: targets.green[1] });
    await until(() => events().slice(before).find(e => e.event === "down" && e.green), "green click");
    report(`${sizing}: screenshot-pixel click hit the target after re-reading the restored window`);
    const shownChild = await command("show-child", "child-shown");
    const composed = await client.getAppState(fixtureApp);
    assert.equal(composed.appSnapshot.coordinateSpace, undefined);
    const composedTargets = locate(composed.appSnapshot.screenshot.url, `${sizing}-composed`);
    sameMarkers(composedTargets, targets, "composition keeps image dimensions and marker positions");
    assert.ok(fs.existsSync(new URL(shot.screenshot.url)), "earlier image remains available after next capture");
    // Composition explicitly passes the primary window and optionally the cursor.
    // Keep the legacy compositor assertion and calibrate the review target independently.
    if (!reviewSettings) assert.ok(composedTargets.magenta, "child panel pixels must appear in the legacy composed screenshot");
    const childTarget = reviewSettings ? toPixel(shownChild.centerScreen) : composedTargets.magenta;
    fs.writeFileSync(path.join(temp, `${sizing}-child-geometry.json`), JSON.stringify({ childTarget, shownChild, composedTargets }, null, 2));
    const beforeChildClick = events().length;
    await client.click({ app: fixtureApp, x: childTarget[0], y: childTarget[1] });
    const childClick = await until(() => events().slice(beforeChildClick).find(e => e.event === "child-down"), "click reaches the visible child window");
    assert.equal(childClick.window, shownChild.windowID);
    assert.equal(events().slice(beforeChildClick).filter(e => e.event === "down").length, 0, "child-window coordinates must not click the underlying parent");
    const beforeChildScroll = events().length;
    await client.scroll({ app: fixtureApp, x: childTarget[0], y: childTarget[1], direction: "down", pages: 1 });
    const childScroll = await until(() => events().slice(beforeChildScroll).find(e => e.event === "child-scroll"), "wheel reaches child window");
    assert.equal(childScroll.window, shownChild.windowID);
    assert.equal(events().slice(beforeChildScroll).filter(e => e.event === "scroll").length, 0);
    const beforeChildDrag = events().length;
    await client.drag({ app: fixtureApp, fromX: childTarget[0], fromY: childTarget[1],
      toX: childTarget[0] + 6, toY: childTarget[1] + 6 });
    const childUp = await until(() => events().slice(beforeChildDrag).find(e => e.event === "child-up"), "drag releases in child window");
    assert.equal(childUp.window, shownChild.windowID);
    assert.ok(events().slice(beforeChildDrag).some(e => e.event === "child-drag" && e.window === shownChild.windowID));
    assert.equal(events().slice(beforeChildDrag).filter(e => e.event === "down").length, 0);
    await command("hide-child", "child-hidden");
    report(`${sizing}: child-panel input reaches its window and the screenshot crop stays fixed`);
    before = events().length;
    await client.drag({ app: fixtureApp, fromX: targets.red[0], fromY: targets.red[1], toX: targets.blue[0], toY: targets.blue[1] });
    await until(() => events().slice(before).find(e => e.event === "up" && e.drop), "drag/drop");
    report(`${sizing}: screenshot-pixel drag reached the drop target`);
    const slider = await command("slider-reset", "slider-ready");
    const [fromX, fromY] = toPixel(slider.from);
    const [toX, toY] = toPixel(slider.to);
    const beforeSlider = events().length;
    await client.drag({ app: fixtureApp, fromX, fromY, toX, toY });
    const sliderStatus = await command("slider-status", "slider-status");
    assert.ok(Math.abs(sliderStatus.value - 80) <= 5, `slider ended at ${sliderStatus.value}, expected about 80`);
    // A drag posts only start, midpoint and destination drag events
    // and AppKit coalesces mouse-dragged
    // events, so an intermediate slider value is not guaranteed; the change is.
    assert.ok(events().slice(beforeSlider).some(e => e.event === "slider-change"),
      "the slider reports a change during the drag");
    report(`${sizing}: screenshot-pixel drag moved the real continuous slider`);
    before = events().length;
    await client.scroll({ app: fixtureApp, x: targets.green[0], y: targets.green[1], direction: "down", pages: 1 });
    await until(() => events().slice(before).find(e => e.event === "scroll" && e.green), "scroll target");
    report(`${sizing}: scrolling used the same image coordinates`);
    // Native mapping is unclipped; targeting rejects a point
    // outside every registered window with -10005 windowNotFoundAtPosition.
    // The point lies over the decoy, but the registry only holds the primary
    // window seeded when the controller was created plus windows created
    // later; the pre-existing decoy is never registered.
    const beforeInvalidClick = events().length;
    await assert.rejects(client.click({ app: fixtureApp, x: targets.__size[0] + 20, y: 10 }),
      e => e.code === -10005 && /windowNotFoundAtPosition\(/.test(e.message));
    assert.equal(events().slice(beforeInvalidClick).filter(e => e.event === "down" || e.event === "observed").length, 0,
      "targeting fails before any event is posted");
    report(`${sizing}: outside-window click returns the targeting error before mouse-down`);
    // The drag destination is mapped without any bounds check, and only the
    // start point is targeted. The drag runs in the window it starts in and
    // releases outside it (the canvas is 620 points wide), off the drop target.
    const beforeOutsideDrag = events().length;
    await client.drag({ app: fixtureApp, fromX: targets.red[0], fromY: targets.red[1],
      toX: targets.__size[0] + 20, toY: targets.blue[1] });
    const outsideUp = await until(() => events().slice(beforeOutsideDrag).find(e => e.event === "up"), "drag releases outside the window");
    assert.ok(events().slice(beforeOutsideDrag).some(e => e.event === "down" && e.red), "the drag starts on the red source");
    assert.equal(outsideUp.drop, false, "a release outside the window does not drop");
    assert.ok(outsideUp.x >= 620, `release at x=${outsideUp.x} should lie past the window's right edge`);
    report(`${sizing}: a drag destination outside the image is not rejected; it releases past the window edge`);
    if (sizing === "legacy") {
      await command("move", "moved");
      // Pixels map through the last capture's origin; moving the
      // window does not invalidate it. The old point still lies inside the
      // moved window, so the click lands there, beside the green target.
      before = events().length;
      const stale = await client.click({ app: fixtureApp, x: targets.green[0], y: targets.green[1] });
      const staleDown = await until(() => events().slice(before).find(e => e.event === "down"), "stale click reaches the moved window");
      assert.equal(staleDown.green, false, "stale coordinates miss the moved target");
      assert.ok(stale.appSnapshot?.screenshot, "the action reply carries a capture of the moved window");
      const fresh = await client.getAppState(fixtureApp);
      // Markers are window-relative, so the moved capture keeps their pixels.
      sameMarkers(locate(fresh.appSnapshot.screenshot.url, `${sizing}-moved`), targets, "the moved window keeps marker pixels");
      before = events().length;
      await client.click({ app: fixtureApp, x: targets.green[0], y: targets.green[1] });
      await until(() => events().slice(before).find(e => e.event === "down" && e.green), "click after recapture");
      report("stale coordinates land at the old screen point after movement; recapture restored targeting");
      await command("close", "closed");
      // Ordering keeps only registered windows that are on screen. With the
      // captured window ordered out none remains (the decoy is on screen but
      // unregistered), so targeting fails with noWindowsAvailable
      // before mouse-down.
      before = events().length;
      await assert.rejects(client.drag({ app: fixtureApp, fromX: targets.red[0], fromY: targets.red[1], toX: targets.blue[0], toY: targets.blue[1] }),
        e => e.code === -10005 && /noWindowsAvailable/.test(e.message));
      assert.equal(events().slice(before).filter(e => e.event === "down").length, 0);
      report("drag rejected with noWindowsAvailable when the captured window is no longer onscreen");
    }
    for (const transport of client.transports.values()) (await transport).close?.();
    if (service.exitCode === null && service.signalCode === null) {
      const stopped = once(service, "exit");
      service.kill("SIGTERM");
      await stopped;
    }
    service = undefined;
  }
  console.log(`ALL COORDINATE INTEGRATION CHECKS PASSED — artifacts: ${temp}`);
} finally {
  service?.kill("SIGTERM");
  fixtureProcess.kill("SIGTERM");
}
