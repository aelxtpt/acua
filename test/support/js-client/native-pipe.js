// JSON-RPC transport over the ACUA service's Unix socket. Each frame is a
// little-endian 32-bit length followed by a UTF-8 JSON body. The socket comes
// from `globalThis.nodeRepl`: its `nativePipe.createConnection(path)` opens
// the connection and `env.ACUA_SERVICE_NATIVE_PIPE_PATH` names the socket.
// The transport never launches the service.
import { Buffer } from "node:buffer";
import { AexComputerUseTransportError, AexComputerUseError, ServerErrorCode } from "./errors.js";

const MAX_FRAME_BYTES = 8388608;
const CONNECT_TIMEOUT_MS = 250;
const SOCKET_PATH_VARIABLE = "ACUA_SERVICE_NATIVE_PIPE_PATH";

export function encodeMessageFrame(str) {
  const body = Buffer.from(str, "utf8");
  if (body.length > MAX_FRAME_BYTES)
    throw new AexComputerUseTransportError(`ACUA native pipe frame is too large: ${body.length}`);
  const frame = Buffer.alloc(4 + body.length);
  frame.writeUInt32LE(body.length, 0);
  body.copy(frame, 4);
  return frame;
}

export function decodeMessageFrames(buf) {
  const messages = [];
  let offset = 0;
  for (;;) {
    if (buf.length - offset < 4) break;
    const length = buf.readUInt32LE(offset);
    if (length > MAX_FRAME_BYTES) throw new AexComputerUseTransportError(`ACUA native pipe frame is too large: ${length}`);
    const end = 4 + length;
    if (buf.length - offset < end) break;
    messages.push(buf.subarray(offset + 4, offset + end).toString("utf8"));
    offset += end;
  }
  return { messages, remainingData: buf.subarray(offset) };
}

function invalidResponse() {
  return new AexComputerUseTransportError("ACUA returned an invalid JSON-RPC response");
}
function parseResponse(value) {
  if (typeof value !== "object" || value == null || !("id" in value) || typeof value.id !== "number" || !("jsonrpc" in value) || value.jsonrpc !== "2.0")
    throw invalidResponse();
  const hasResult = Object.prototype.hasOwnProperty.call(value, "result");
  const hasError = Object.prototype.hasOwnProperty.call(value, "error");
  if (hasResult === hasError) throw invalidResponse();
  if (hasResult) return { id: value.id, jsonrpc: "2.0", result: Reflect.get(value, "result") };
  const error = Reflect.get(value, "error");
  if (typeof error !== "object" || error == null || !("code" in error) || typeof error.code !== "number" || !("message" in error) || typeof error.message !== "string")
    throw invalidResponse();
  return { id: value.id, jsonrpc: "2.0", error: { code: error.code, message: error.message } };
}

function requireNodeRepl() {
  const nodeRepl = globalThis.nodeRepl;
  if (nodeRepl == null) throw new AexComputerUseTransportError("ACUA requires the globalThis.nodeRepl runtime");
  return nodeRepl;
}
function stringOrUndefined(v) {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t === "" ? undefined : t;
}
function asError(e) { return e instanceof Error ? e : new Error(String(e)); }
function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function raceTimeout(promise, ms, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), ms); })]);
  } finally { if (timer != null) clearTimeout(timer); }
}
function coerceMetadata(value) {
  if (value == null) return value;
  if (typeof value === "object" && !ArrayBuffer.isView(value)) return value;
  return JSON.parse(Buffer.from(value).toString("utf8"));
}

class TransportUnavailableError extends Error {
  constructor(cause) { super(`ACUA native pipe is unavailable: ${cause instanceof Error ? cause.message : String(cause)}`); }
}
class VersionMismatchError extends AexComputerUseTransportError {}

export class MacNativePipeTransport {
  #seq = 1;
  #buffer = Buffer.alloc(0);
  #pending = new Map();
  #queue = Promise.resolve();
  #socket = null;

  static async create(apiVersion) {
    const nodeRepl = requireNodeRepl();
    const nativePipe = nodeRepl.nativePipe;
    if (nativePipe == null || typeof nativePipe.createConnection !== "function")
      throw new AexComputerUseTransportError("ACUA native pipe is unavailable");
    const sockPath = stringOrUndefined(nodeRepl.env?.[SOCKET_PATH_VARIABLE]);
    if (sockPath == null) throw new AexComputerUseTransportError(`${SOCKET_PATH_VARIABLE} is required`);
    try {
      return await this.connect(nativePipe.createConnection, sockPath, apiVersion, CONNECT_TIMEOUT_MS);
    } catch (err) {
      if (!(err instanceof TransportUnavailableError)) throw err;
      throw new AexComputerUseTransportError("ACUA native pipe connection failed", { cause: err });
    }
  }

  static async connect(nativeCreateConnection, sockPath, apiVersion, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    let lastError;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new TransportUnavailableError(lastError);
      let connection;
      const attempt = nativeCreateConnection(sockPath);
      try { connection = await raceTimeout(attempt, remaining, "ACUA native pipe connection timed out"); }
      catch (e) { attempt.then((c) => c.end(), () => {}); lastError = e; }
      if (connection != null) {
        const transport = new MacNativePipeTransport(connection, apiVersion);
        try {
          await transport.ping(Math.min(1000, Math.max(1, deadline - Date.now())));
          return transport;
        } catch (e) {
          transport.#kill();
          if (e instanceof VersionMismatchError || (e instanceof AexComputerUseError && e.code === ServerErrorCode.incompatibleClientVersion)) throw e;
          lastError = e;
        }
      }
      if (Date.now() >= deadline) throw new TransportUnavailableError(lastError);
      await delay(100);
    }
  }

  constructor(socket, apiVersion) {
    this.apiVersion = apiVersion;
    this.#socket = socket;
    socket.on("data", (chunk) => {
      try { this.#onData(chunk); }
      catch (e) { this.#fail(asError(e)); socket.end(); }
    });
    socket.on("error", (e) => this.#fail(e));
    socket.on("close", () => this.#fail(new Error("ACUA native pipe closed before response")));
  }

  get isClosed() { return this.#socket == null; }

  async request({ requestType, request, timeoutSeconds, agentMetadata }) {
    const timeoutMs = 1000 * timeoutSeconds;
    const next = this.#queue.then(() => this.#send("request", {
      clientApiVersion: this.apiVersion,
      agentTurnMetadata: coerceMetadata(agentMetadata),
      deadlineUnixMilliseconds: Date.now() + timeoutMs,
      request,
      requestType,
    }, timeoutMs));
    this.#queue = next.then(() => {}, () => {});
    return await next;
  }

  async ping(timeoutMs) {
    const res = await this.#send("ping", { clientApiVersion: this.apiVersion }, timeoutMs);
    if (res.serverApiVersion !== this.apiVersion)
      throw new VersionMismatchError(`ACUA API version mismatch: client=${this.apiVersion} server=${String(res.serverApiVersion)}`);
  }

  #send(method, params, timeoutMs) {
    const socket = this.#socket;
    if (socket == null) return Promise.reject(new AexComputerUseTransportError("ACUA native pipe is closed"));
    const id = this.#seq++;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, {
        resolve,
        reject,
        timeout: setTimeout(() => { this.#fail(new AexComputerUseTransportError(`ACUA ${method} timed out`)); socket.end(); }, timeoutMs),
      });
      try {
        socket.write(encodeMessageFrame(JSON.stringify({ id, jsonrpc: "2.0", method, params })));
      } catch (e) {
        const pending = this.#pending.get(id);
        if (pending != null) { this.#pending.delete(id); clearTimeout(pending.timeout); }
        reject(asError(e));
      }
    });
  }

  #onData(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, Buffer.from(chunk)]);
    const { messages, remainingData } = decodeMessageFrames(this.#buffer);
    this.#buffer = remainingData;
    for (const message of messages) this.#onResponse(parseResponse(JSON.parse(message)));
  }

  #onResponse(response) {
    const pending = this.#pending.get(response.id);
    if (pending == null) return;
    this.#pending.delete(response.id);
    clearTimeout(pending.timeout);
    if ("error" in response) pending.reject(new AexComputerUseError({ code: response.error.code, message: response.error.message, request: null, requestType: "jsonRPC" }));
    else pending.resolve(response.result);
  }

  #fail(error) {
    if (this.#socket == null) return;
    this.#socket = null;
    for (const pending of this.#pending.values()) { clearTimeout(pending.timeout); pending.reject(error); }
    this.#pending.clear();
  }

  #kill() {
    const socket = this.#socket;
    this.#socket = null;
    socket?.end();
  }
}
