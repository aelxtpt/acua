import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import path from 'node:path';

export function requireNativeDesktop() {
  const executable = process.env.CUA_REVIEW_LAUNCHER || process.env.CUA_NATIVE_AUTOMATION_HARNESS;
  assert.ok(executable, 'Build the temporary native dispatch harness before running this test');
  const diagnostics = JSON.parse(execFileSync(executable, ['--diagnostics'], { encoding: 'utf8' }));
  assert.ok(!diagnostics.screenLocked && diagnostics.accessibility && diagnostics.screenRecording, JSON.stringify(diagnostics));
}

export function startNativeDesktop(directory, bundle, mode = 'standard', socketName = 'service.sock') {
  const review = process.env.CUA_REVIEW_DESKTOP_LAUNCHER;
  const executable = review || process.env.CUA_NATIVE_AUTOMATION_HARNESS;
  const socket = path.join(directory, socketName);
  const env = review ? { ...process.env, CUA_REVIEW_DESKTOP_BUNDLE: bundle, CUA_REVIEW_DESKTOP_MODE: mode } : {
    ...process.env, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS: '1', CODEX_HOME: directory,
    ACUA_SCREENSHOT_DIRECTORY: path.join(directory, 'shots'),
  };
  return { socket, service: spawn(executable, [socket], { env, stdio: ['ignore', 'ignore', 'inherit'] }) };
}
