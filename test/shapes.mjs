import { MacComputerUseClient } from "./support/js-client/client.js";

globalThis.nodeRepl = { env: {}, requestMeta: {} };

const captured = [];
class FakeTransport {
  isClosed = false;
  async request(req) { captured.push(req); return req.requestType === "ComputerUseIPCListAppsRequest" ? [] : {}; }
}
const make = () => {
  const c = new MacComputerUseClient();
  c.transports.set(c.apiVersion, Promise.resolve(new FakeTransport()));
  return c;
};
let failures = 0;
function eq(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  const ok = a === e;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `\n   got:      ${a}\n   expected: ${e}`}`);
  if (!ok) failures++;
}
async function act(name, fn, requestType, request) {
  const c = make();
  captured.length = 0;
  await fn(c);
  eq(name, captured[0], { requestType, request, timeoutSeconds: 120, agentMetadata: undefined });
}

const PERFORM = "ComputerUseIPCAppPerformActionRequest";
const APP_SNAPSHOT = "ComputerUseIPCAppGetAppSnapshotRequest";

await act("listApps", (c) => c.listApps(), "ComputerUseIPCListAppsRequest", {});
await act("getAppPolicy", (c) => c.getAppPolicy("com.apple.finder"), "ComputerUseIPCAppPolicyRequest", { app: "com.apple.finder" });
await act("getAppState string", (c) => c.getAppState("A"), APP_SNAPSHOT, { app: "A" });
await act("getAppState disableDiff", (c) => c.getAppState({ app: "A", disableDiff: true }), APP_SNAPSHOT, { app: "A", disableDiff: true });
await act("startApp", (c) => c.startApp("A"), "ComputerUseIPCAppStartRequest", { app: "A" });
await act("stopApp", (c) => c.stopApp("A"), "ComputerUseIPCAppStopRequest", { app: "A" });
await act("modify activate", (c) => c.modifyApp("A", "activate"), "ComputerUseIPCAppModifyRequest", { app: "A", modification: { activate: {} } });
await act("modify deactivate", (c) => c.modifyApp("A", "deactivate"), "ComputerUseIPCAppModifyRequest", { app: "A", modification: { deactivate: {} } });
await act("frontmost window", (c) => c.getFrontmostWindow(), "ComputerUseIPCFrontmostWindowRequest", {});
await act("start capture", (c) => c.startAppCapture({ app: "A", requestID: "capture", permissionRequestID: "permission", version: 2 }), "ComputerUseIPCAppStartCaptureRequest", { app: "A", version: 2, requestId: "capture", permissionRequestId: "permission" });
await act("start capture prefers native keys", (c) => c.startAppCapture({ app: "A", requestId: "native", requestID: "legacy", permissionRequestId: null, permissionRequestID: "legacy" }), "ComputerUseIPCAppStartCaptureRequest", { app: "A", requestId: "native", permissionRequestId: null });
await act("next capture update", (c) => c.nextAppCaptureUpdate("capture"), "ComputerUseIPCAppNextCaptureUpdateRequest", { requestId: "capture" });
await act("startAudioRecording", (c) => c.startAudioRecording({ maxDurationMilliseconds: 60000 }), "ComputerUseIPCStartAudioRecordingRequest", { maxDurationMilliseconds: 60000 });
await act("stopAudioRecording", (c) => c.stopAudioRecording(), "ComputerUseIPCStopAudioRecordingRequest", {});

await act("click by element", (c) => c.click({ app: "A", elementIndex: 3, clickCount: 2, mouseButton: "right", key: "Shift", duration: 0.5 }), PERFORM,
  { app: "A", action: { click: { at: { elementID: { _0: "3" } }, clickCount: 2, key: "Shift", duration: 0.5, mouseButton: 1 } } });
await act("click by coordinate (defaults)", (c) => c.click({ app: "A", x: 10, y: 20 }), PERFORM,
  { app: "A", action: { click: { at: { coordinate: { _0: [10, 20] } }, clickCount: 1, mouseButton: 0 } } });
await act("drag", (c) => c.drag({ app: "A", fromX: 1, fromY: 2, toX: 3, toY: 4 }), PERFORM,
  { app: "A", action: { drag: { from: [1, 2], to: [3, 4] } } });
await act("paste", (c) => c.paste({ app: "A", text: "hi", format: "text" }), PERFORM,
  { app: "A", action: { paste: { text: "hi", format: "text" } } });
await act("performSecondaryAction", (c) => c.performSecondaryAction({ app: "A", elementIndex: 5, action: "AXShowMenu" }), PERFORM,
  { app: "A", action: { performSecondaryAction: { action: "AXShowMenu", elementID: "5" } } });
await act("pressKey", (c) => c.pressKey({ app: "A", key: "Return", duration: 0.2 }), PERFORM,
  { app: "A", action: { pressKey: { _0: "Return", duration: 0.2 } } });
await act("scroll by coordinate", (c) => c.scroll({ app: "A", x: 9, y: 8, direction: "D", pages: 2 }), PERFORM,
  { app: "A", action: { scroll: { at: { coordinate: { _0: [9, 8] } }, direction: "down", pages: 2 } } });
await act("setValue", (c) => c.setValue({ app: "A", elementIndex: 7, value: "v" }), PERFORM,
  { app: "A", action: { setValue: { elementID: "7", value: "v" } } });
await act("selectText", (c) => c.selectText({ app: "A", elementIndex: 7, text: "t", prefix: "p", suffix: "s" }), PERFORM,
  { app: "A", action: { selectText: { elementID: "7", text: "t", prefix: "p", suffix: "s", selection: "text" } } });
await act("typeText", (c) => c.typeText({ app: "A", text: "hello" }), PERFORM,
  { app: "A", action: { type: { _0: "hello" } } });

// validation errors mirror the shipped client
const throws = (name, fn, msg) => {
  try { fn(); console.log(`FAIL ${name} (no throw)`); failures++; }
  catch (e) { const ok = e.message === msg; console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` (${e.message})`}`); if (!ok) failures++; }
};
throws("click requires finite duration", () => make().click({ app: "A", duration: NaN }), "duration must be a finite number");
throws("click needs element or coordinate", () => make().click({ app: "A" }), "coordinate must include finite x and y coordinates");
throws("pressKey needs key", () => make().pressKey({ app: "A", key: " " }), "key is required");
throws("scroll pages > 0", () => make().scroll({ app: "A", x: 1, y: 1, direction: "up", pages: 0 }), "pages must be a finite number > 0");
throws("unknown session modification", () => make().modifyApp("A", "hide"), "operation must be activate or deactivate");
throws("capture requires a request ID", () => make().startAppCapture({ app: "A" }), "requestID is required");
throws("next capture requires a request ID", () => make().nextAppCaptureUpdate(" "), "requestID is required");

console.log(`\n${failures === 0 ? "ALL SHAPE TESTS PASSED" : failures + " FAILURE(S)"}`);
process.exitCode = failures ? 1 : 0;
