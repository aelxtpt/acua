// A minimal MCP client over stdio for integration tests, as an MCP host runs
// the packaged helper: newline-delimited JSON-RPC on stdin and stdout.
//
// It answers server requests (elicitation/create) through `onRequest`, and
// keeps every message it receives so a test can assert on what did, or did
// not, arrive.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const PROTOCOL_VERSION = '2025-06-18';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export function packagedHelper() {
  const bundle = process.env.CUA_REVIEW_BUNDLE || path.join(root, 'service/.build/current/dist/AexComputerUseService.app');
  const helper = path.join(bundle, 'Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient');
  assert.ok(fs.existsSync(helper), `MCP helper not found: ${helper}`);
  return helper;
}

/// The command line that starts each of the five servers.
export const SERVERS = {
  'computer-use': ['mcp'],
  calendar: ['calendar', 'mcp'],
  'computer-history': ['computer-history', 'mcp'],
  'event-stream': ['event-stream', 'mcp'],
  messages: ['messages', 'mcp'],
};

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

export class MCPStdioClient {
  #child;
  #buffered = '';
  #nextID = 0;
  #errors = '';
  /// Every message received, in order.
  messages = [];
  /// Answers a server request: (message) => result object, or undefined to leave it unanswered.
  onRequest = () => undefined;

  constructor(args, {env = process.env} = {}) {
    this.#child = spawn(packagedHelper(), args, {stdio: ['pipe', 'pipe', 'pipe'], env});
    this.#child.stderr.on('data', chunk => this.#errors += chunk);
    this.#child.stdout.on('data', chunk => this.#receive(chunk));
  }

  get stderr() { return this.#errors; }

  #receive(chunk) {
    this.#buffered += chunk;
    let newline;
    while ((newline = this.#buffered.indexOf('\n')) >= 0) {
      const line = this.#buffered.slice(0, newline).trim();
      this.#buffered = this.#buffered.slice(newline + 1);
      if (!line)
        continue;

      const message = JSON.parse(line);
      this.messages.push(message);
      if (message.method !== undefined && message.id !== undefined)
        this.#answer(message);
    }
  }

  #answer(request) {
    const result = this.onRequest(request);
    if (result !== undefined)
      this.send({jsonrpc: '2.0', id: request.id, result});
  }

  /// Writes one raw line, for malformed input.
  writeLine(text) {
    this.#child.stdin.write(text + '\n');
  }

  send(message) {
    this.writeLine(JSON.stringify(message));
  }

  notify(method, params) {
    this.send(params === undefined ? {jsonrpc: '2.0', method} : {jsonrpc: '2.0', method, params});
  }

  /// Sends a request and returns its id without waiting.
  start(method, params) {
    const id = ++this.#nextID;
    this.send({jsonrpc: '2.0', id, method, params});
    return id;
  }

  /// The first received message matching `predicate`, waiting up to `timeout` ms; null if none arrived.
  async waitFor(predicate, timeout = 15000) {
    const until = Date.now() + timeout;
    for (;;) {
      const message = this.messages.find(predicate);
      if (message)
        return message;

      if (Date.now() >= until || this.#child.exitCode !== null)
        return null;

      await sleep(10);
    }
  }

  /// The full JSON-RPC response to request `id`.
  async response(id, timeout = 15000) {
    const message = await this.waitFor(message => message.id === id && message.method === undefined, timeout);
    assert.ok(message, `no response to request ${id}: ${this.#errors}`);
    return message;
  }

  /// The result of a request; fails on a JSON-RPC error.
  async request(method, params, timeout) {
    const reply = await this.response(this.start(method, params), timeout);
    assert.equal(reply.error, undefined, `${method} failed: ${JSON.stringify(reply.error)}`);
    return reply.result;
  }

  async initialize(capabilities = {}, protocolVersion = PROTOCOL_VERSION) {
    const result = await this.request('initialize', {protocolVersion, capabilities,
      clientInfo: {name: 'acua-mcp-test-client', version: '1'}});
    this.notify('notifications/initialized');
    return result;
  }

  callTool(name, args = {}, timeout) {
    return this.request('tools/call', {name, arguments: args}, timeout);
  }

  close() {
    this.#child.stdin.end();
    this.#child.kill('SIGTERM');
  }
}

/// The text content of a tool result.
export function resultText(result) {
  return (result.content ?? []).filter(item => item.type === 'text').map(item => item.text).join('\n');
}
