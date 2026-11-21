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
