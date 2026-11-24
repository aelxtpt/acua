import fs from 'node:fs';
// Fixtures use an ad-hoc service and unsigned Node clients. Opt in explicitly;
// normal service startup keeps the signature gate enabled.
export function serviceTestEnvironment(overrides = {}) {
  return { ...process.env, ...overrides, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS: '1' };
}

export function serviceTestExecutable(projectRoot) {
  return process.env.CUA_REVIEW_LAUNCHER || `${projectRoot}/service/AexComputerUseService`;
}

export function serviceTestRustManifest(projectRoot) {
  return process.env.CUA_REVIEW_RUST_MANIFEST || `${projectRoot}/rust/cua-client/Cargo.toml`;
}

// Copies of disposable fixture apps left by earlier runs stay registered with
// Launch Services, and the service refuses a bundle identifier that two apps
// share as ambiguous. Every run therefore names its fixtures uniquely; the
// suffix is fixed per process so one test can rebuild the same name.
const fixtureRunSuffix = `run-${process.pid}-${Date.now().toString(36)}`;

export function uniqueFixtureBundle(base) {
  return `${base}.${fixtureRunSuffix}`;
}

// The service resolves a bundle identifier through Launch Services, and
// Launch Services ignores apps in temporary directories.
// Fixtures live there, so requests name them by path. The path is given in
// Foundation's canonical form (/tmp rather than /private/tmp): sessions are
// keyed by it, and a stop marks its identifier exactly as received.
export function fixtureAppTarget(appPath) {
  return fs.realpathSync(appPath).replace(/^\/private(?=\/)/, '');
}
