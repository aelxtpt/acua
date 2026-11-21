import { MacNativePipeTransport } from "./native-pipe.js";
export { AexComputerUseError, AexComputerUseTransportError } from "./errors.js";

const APP_POLICY_REQUEST = "ComputerUseIPCAppPolicyRequest";
const START_AUDIO_REQUEST = "ComputerUseIPCStartAudioRecordingRequest";
const STOP_AUDIO_REQUEST = "ComputerUseIPCStopAudioRecordingRequest";
const GET_APP_SNAPSHOT_REQUEST = "ComputerUseIPCAppGetAppSnapshotRequest";
const LIST_APPS_REQUEST = "ComputerUseIPCListAppsRequest";
const PERFORM_ACTION_REQUEST = "ComputerUseIPCAppPerformActionRequest";
const APP_START_REQUEST = "ComputerUseIPCAppStartRequest";

export class MacComputerUseClient {
  transports = new Map();
  apiVersion;
  agentMetadata;
  timeoutSeconds;

  constructor(options = {}) {
    this.apiVersion = options.apiVersion ?? "AcuaComputerUseIPC-5";
    this.agentMetadata = options.agentMetadata;
    this.timeoutSeconds = options.timeoutSeconds ?? 120;
  }

  listApps(options = {}) { return this.request(LIST_APPS_REQUEST, {}, options); }
  startAudioRecording(request, options = {}) { return this.request(START_AUDIO_REQUEST, request, options); }
  stopAudioRecording(options = {}) { return this.request(STOP_AUDIO_REQUEST, {}, options); }
  getAppPolicy(app, options = {}) { return this.request(APP_POLICY_REQUEST, appIdentifier(app), options); }
  startApp(app, options = {}) { return this.request(APP_START_REQUEST, appIdentifier(app), options); }
  stopApp(app, options = {}) { return this.request("ComputerUseIPCAppStopRequest", appRef(app), options); }
  modifyApp(app, operation, options = {}) {
    if (!["activate", "deactivate"].includes(operation)) throw new TypeError("operation must be activate or deactivate");
    return this.request("ComputerUseIPCAppModifyRequest", { ...appRef(app), modification: { [operation]: {} } }, options);
  }
  getFrontmostWindow(options = {}) { return this.request("ComputerUseIPCFrontmostWindowRequest", {}, options); }
  startAppCapture(input, options = {}) {
    const { requestId, requestID, permissionRequestId, permissionRequestID, ...fields } = input ?? {};
    const id = requestId === undefined ? requestID : requestId;
    if (typeof id !== "string" || id.trim() === "") throw new TypeError("requestID is required");
    const permission = permissionRequestId === undefined ? permissionRequestID : permissionRequestId;
    return this.request("ComputerUseIPCAppStartCaptureRequest", {
      ...fields, ...appRef(fields.app), requestId: id, permissionRequestId: permission,
    }, options);
  }
  nextAppCaptureUpdate(requestID, options = {}) {
    if (typeof requestID !== "string" || requestID.trim() === "") throw new TypeError("requestID is required");
    return this.request("ComputerUseIPCAppNextCaptureUpdateRequest", { requestId: requestID }, options);
  }
  getAppState(input, options = {}) {
    const request = typeof input === "string" ? appRef(input) : { ...appRef(input.app), disableDiff: input.disableDiff };
    return this.request(GET_APP_SNAPSHOT_REQUEST, request, options);
  }

  click(input, options = {}) {
    if (input.duration !== undefined && !Number.isFinite(input.duration)) throw new TypeError("duration must be a finite number");
    const clickCount = input.clickCount === undefined ? 1 : input.clickCount;
    const mouseButton = input.mouseButton === undefined ? "left" : input.mouseButton;
    return this.performAction(input.app, {
      click: { at: clickTarget(input), clickCount, key: input.key, duration: input.duration, mouseButton: resolveMouseButton(mouseButton) },
    }, options);
  }
  drag(input, options = {}) {
    return this.performAction(input.app, {
      drag: { from: coordinatePair({ x: input.fromX, y: input.fromY }, "from"), to: coordinatePair({ x: input.toX, y: input.toY }, "to") },
    }, options);
  }
  paste(input, options = {}) { return this.performAction(input.app, { paste: { text: input.text, format: input.format } }, options); }
  performSecondaryAction(input, options = {}) {
    return this.performAction(input.app, { performSecondaryAction: { action: input.action, elementID: elementId(input.elementIndex) } }, options);
  }
  pressKey(input, options = {}) {
    if (input.key.trim() === "") throw new TypeError("key is required");
    if (input.duration !== undefined && !Number.isFinite(input.duration)) throw new TypeError("duration must be a finite number");
    return this.performAction(input.app, { pressKey: { _0: input.key, duration: input.duration } }, options);
  }
  scroll(input, options = {}) {
    const pages = input.pages === undefined ? 1 : input.pages;
    if (!Number.isFinite(pages) || pages <= 0) throw new TypeError("pages must be a finite number > 0");
    return this.performAction(input.app, {
      scroll: { at: scrollTarget(input), direction: resolveDirection(input.direction), pages },
    }, options);
  }
  setValue(input, options = {}) {
    return this.performAction(input.app, { setValue: { elementID: elementId(input.elementIndex), value: input.value } }, options);
  }
  selectText(input, options = {}) {
    const selection = input.selection === undefined ? "text" : input.selection;
    return this.performAction(input.app, {
      selectText: { elementID: elementId(input.elementIndex), text: input.text, prefix: input.prefix, suffix: input.suffix, selection },
    }, options);
  }
  typeText(input, options = {}) { return this.performAction(input.app, { type: { _0: input.text } }, options); }

  performAction(app, action, options) { return this.request(PERFORM_ACTION_REQUEST, { ...appRef(app), action }, options); }

  async request(requestType, request, options = {}) {
    const apiVersion = options.apiVersion ?? this.apiVersion;
    const transport = await this.getTransport(apiVersion);
    return transport.request({
      requestType,
      request: stripUndefined(request),
      timeoutSeconds: options.timeoutSeconds ?? this.timeoutSeconds,
      agentMetadata: selectMetadata(options, this.agentMetadata),
    });
  }

  async getTransport(apiVersion) {
    for (;;) {
      const pending = this.transport(apiVersion);
      try {
        const transport = await pending;
        if (!transport.isClosed) return transport;
        if (this.transports.get(apiVersion) === pending) this.transports.delete(apiVersion);
      } catch (e) {
        if (this.transports.get(apiVersion) === pending) this.transports.delete(apiVersion);
        throw e;
      }
    }
  }
  transport(apiVersion) {
    let pending = this.transports.get(apiVersion);
    if (pending == null) { pending = MacNativePipeTransport.create(apiVersion); this.transports.set(apiVersion, pending); }
    return pending;
  }
}

export const client = new MacComputerUseClient();

function turnMetadataHeader() {
  return globalThis.nodeRepl?.requestMeta?.["x-codex-turn-metadata"];
}
function selectMetadata(options, fallback) {
  if (options.agentMetadata !== undefined) return options.agentMetadata;
  if (fallback !== undefined) return fallback;
  return turnMetadataHeader();
}
function appIdentifier(input) {
  return appRef(typeof input === "string" ? input : input.app);
}
function appRef(app) {
  if (app == null || app.trim() === "") throw new TypeError("app is required");
  return { app };
}
function clickTarget(input) {
  return input.elementIndex == null
    ? { coordinate: { _0: coordinatePair({ x: input.x, y: input.y }, "coordinate") } }
    : { elementID: { _0: elementId(input.elementIndex) } };
}
const scrollTarget = clickTarget;
function coordinatePair(point, label) {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) throw new TypeError(`${label} must include finite x and y coordinates`);
  return [Number(point.x), Number(point.y)];
}
function elementId(index) {
  if (!Number.isInteger(index)) throw new TypeError("elementIndex must be an integer");
  return String(index);
}
function resolveMouseButton(button) {
  if (typeof button === "number") {
    if ([0, 1, 2].includes(button)) return button;
    throw new TypeError("mouseButton number must be 0, 1, or 2");
  }
  switch (button.trim().toLowerCase()) {
    case "l": case "left": return 0;
    case "r": case "right": return 1;
    case "m": case "middle": return 2;
    default: throw new TypeError("mouseButton must be left, right, middle, l, r, m, 0, 1, or 2");
  }
}
function resolveDirection(direction) {
  switch (direction.trim().toLowerCase()) {
    case "u": case "up": return "up";
    case "d": case "down": return "down";
    case "l": case "left": return "left";
    case "r": case "right": return "right";
    default: throw new TypeError("direction must be up, down, left, or right");
  }
}
function stripUndefined(value) {
  if (Array.isArray(value)) return value.map(stripUndefined);
  if (value == null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined).map(([k, v]) => [k, stripUndefined(v)]));
}
