// End-to-end demo against a local ACUA service:
//   quit TextEdit → launch it → click "New Document" → click the text area → type → verify
import net from "node:net";
import os from "node:os";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const SERVICE = path.join(root, "service/AexComputerUseService");
const TEXTEDIT = "com.apple.TextEdit";
const outputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "acua-demo-"));
const sockPath = path.join(outputDirectory, "service.sock");

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const service = spawn(SERVICE, [sockPath], { env: { ...process.env, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS: "1" }, stdio: ["ignore", "ignore", "pipe"] });
service.stderr.on("data", (d) => process.stderr.write(`[svc] ${d}`));

async function waitForSocket(p, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fs.existsSync(p)) return; await sleep(100); }
  throw new Error("service socket did not appear");
}

globalThis.nodeRepl = {
  env: { ...process.env, ACUA_SERVICE_NATIVE_PIPE_PATH: sockPath },
  requestMeta: {},
  nativePipe: { createConnection: (p) => new Promise((res, rej) => { const s = net.createConnection({ path: p }); s.once("connect", () => res(s)); s.once("error", rej); }) },
};

const NOTE = [
  "Hello! This text was typed by ACUA.",
  "Service: AexComputerUseService (Swift, ScreenCaptureKit + AX + CGEvent)",
  "Client: JSON-RPC over a Unix socket",
].join("\n");
const NOTE_MARKER = "typed by ACUA";

const findIndex = (text, role, needle) => {
  const line = text.split("\n").find((l) => l.includes(role) && (needle ? l.includes(needle) : true));
  return line ? Number(line.match(/\[(\d+)\]/)[1]) : undefined;
};

try {
  await waitForSocket(sockPath);
  const { MacComputerUseClient } = await import("../test/support/js-client/client.js");
  const client = new MacComputerUseClient();
  const snapshot = async () => (await client.getAppState(TEXTEDIT)).appSnapshot;

  const policy = await client.getAppPolicy(TEXTEDIT);
  log(`[1] app policy for TextEdit: ${policy.decision}`);
  log("[2] quitting any running TextEdit for a clean start");
  spawnSync("pkill", ["-f", "TextEdit.app/Contents/MacOS/TextEdit"]);
  await sleep(1200);

  log("[3] AppStartRequest → launching TextEdit");
  await client.startApp(TEXTEDIT);
  await sleep(1200);

  log("[4] get_app_state → AX tree");
  let state = await snapshot();
  log(`    ${state.text.length} chars, screenshot=${state.screenshot ? "yes" : "no"}`);

  const newDoc = findIndex(state.text, "AXButton", '"New Document"');
  if (newDoc !== undefined) {
    log(`[5] click element_index=${newDoc} ("New Document")`);
    await client.click({ app: TEXTEDIT, elementIndex: newDoc });
  } else {
    log("[5] no open panel — Cmd+N");
    await client.pressKey({ app: TEXTEDIT, key: "Super_L+n" });
  }
  await sleep(900);

  state = await snapshot();
  const textArea = findIndex(state.text, "AXTextArea");
  log(`[6] click element_index=${textArea} (text area) to focus it`);
  if (textArea !== undefined) await client.click({ app: TEXTEDIT, elementIndex: textArea });
  await sleep(400);

  log("[7] type_text → the note");
  await client.typeText({ app: TEXTEDIT, text: NOTE });
  await sleep(700);

  log("[8] get_app_state → verify");
  let hit = false;
  for (let attempt = 0; attempt < 4 && !hit; attempt++) {
    state = await snapshot();
    hit = state.text.includes(NOTE_MARKER);
    if (!hit) await sleep(350);
  }
  log(`    typed content present: ${hit ? "YES" : "NO"}`);
  for (const l of state.text.split("\n").filter((l) => l.includes(NOTE_MARKER) || l.includes("AexComputerUseService"))) log("    " + l.trim());

  const url = state.screenshot?.url;
  const out = path.join(outputDirectory, "textedit-result.jpg");
  if (url?.startsWith("data:image")) fs.writeFileSync(out, Buffer.from(url.split(",")[1], "base64"));
  if (url?.startsWith("file:")) fs.copyFileSync(fileURLToPath(url), out);
  if (fs.existsSync(out)) log(`    screenshot: ${out} (${fs.statSync(out).size} bytes)`);
  process.exitCode = hit ? 0 : 1;
} finally {
  service.kill("SIGTERM");
}
