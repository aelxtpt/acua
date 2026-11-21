"""Run existing suite groups against an explicitly selected signed review package."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
TEST = PROJECT / "test"
STARTUP_BOUNDARY_SOURCE = TEST / "support/startup-boundary/StartupBoundary.m"
sys.path.insert(0, str(PROJECT / "service"))
import bundle_signing  # noqa: E402
BUNDLE = "Aex Computer Use.app"
RUST = "rust/cua-client"
HEADER = re.compile(r"""(?:echo; )?echo ["']== (.+) ==["']""")
read = lambda path: json.loads(path.read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def sign_like(path, app):
    """Signs `path` with the keychain identity of the team that signed `app`.

    The re-signed test copy keeps library validation, so the inserted boundary
    must be signed by the same team. CODESIGN_IDENTITY wins when it is set.
    Certificate names don't carry the team ID (an Apple Development name holds
    a personal ID), so without it each identity is tried until one matches."""
    team = signing_team(app)
    if not team:
        raise SystemExit("The package has no signing team; build it with CODESIGN_IDENTITY set")
    configured = os.environ.get("CODESIGN_IDENTITY", "")
    candidates = [configured] if configured and configured != "-" else [
        line.split()[1] for line in checked(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).splitlines()
        if re.match(r"\s*\d+\) [0-9A-F]{40} ", line)]
    for identity in candidates:
        signed = subprocess.run(["/usr/bin/codesign", "--force", "--timestamp=none", "--sign", identity, str(path)],
                                capture_output=True)
        if signed.returncode == 0 and signing_team(path) == team:
            return
    raise SystemExit("No code-signing identity for the package's team in the keychain; set CODESIGN_IDENTITY")


def signing_team(path):
    details = subprocess.run(["/usr/bin/codesign", "-dv", str(path)], capture_output=True, text=True).stderr
    team = next((line.split("=", 1)[1] for line in details.splitlines() if line.startswith("TeamIdentifier=")), "")
    return "" if team == "not set" else team


def build_startup_boundary(output, app, minimum_system_version):
    """Compiles the test-only startup boundary and signs it like the package."""
    output.parent.mkdir(parents=True, exist_ok=True)
    checked(["/usr/bin/xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-O2",
             f"-mmacosx-version-min={minimum_system_version}", "-framework", "AppKit",
             "-o", str(output), str(STARTUP_BOUNDARY_SOURCE)])
    sign_like(output, app)
    return output


def suite_groups():
    groups = []
    for line in (TEST / "suite-groups.sh").read_text().splitlines():
        header = HEADER.fullmatch(line)
        if header:
            groups.append({"id": len(groups) + 1, "name": header[1], "body": []})
        elif groups and line != "exit $fail":
            groups[-1]["body"].append(line)
    if not groups or any(not any(group["body"]) for group in groups):
        raise SystemExit("Unable to read the group recipes in test/suite-groups.sh")
    return groups


def checked(argv, cwd=PROJECT):
    return subprocess.check_output(argv, cwd=cwd, text=True, stderr=subprocess.STDOUT, timeout=30)


def verify_package(distribution, run):
    distribution = distribution.resolve(strict=True)
    manifest_path = distribution.parent / "package-build-result.json"
    manifest = read(manifest_path)
    files = manifest["files"]
    for name, digest in files.items():
        artifact = (distribution / name).resolve()
        if not artifact.is_relative_to(distribution) or sha(artifact) != digest:
            raise SystemExit(f"Review package failed the manifest check: {name}")
    bundle_name = manifest.get("app_bundle", BUNDLE)
    if Path(bundle_name).name != bundle_name or not bundle_name.endswith(".app"):
        raise SystemExit("The package manifest requires an application bundle name")
    app = distribution / bundle_name
    executable = f"{bundle_name}/Contents/MacOS/AexComputerUseService"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != "com.aex.computeruse" or info["CFBundleExecutable"] != "AexComputerUseService":
        raise SystemExit("Select a signed ACUA service package that includes its Rust crate")
    checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    build = read(distribution.parent / "native-build-result.json")
    command = build["command"]
    raw = Path(build.get("binary", command[command.index("-o") + 1]))
    if build["exit_code"] != 0 or sha(raw) != build["binary_sha256"]:
        raise SystemExit("The raw service no longer matches the selected build")
    boundary = build_startup_boundary(run / "t/startup-boundary.dylib", app, info["LSMinimumSystemVersion"])
    native_temporary_directory = Path(checked(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"]).strip()).resolve()
    if not str(native_temporary_directory).startswith("/private/var/folders/") or native_temporary_directory.name != "T":
        raise SystemExit("macOS did not provide its per-user temporary directory")
    shutil.copytree(distribution / RUST, run / RUST)
    rust_hashes = {name: value for name, value in files.items() if name.startswith(f"{RUST}/")}
    if not rust_hashes or any(sha(run / name) != value for name, value in rust_hashes.items()):
        raise SystemExit("The test copy of the Rust crate differs from the selected package")
    return dict(
        revision=info["CFBundleVersion"], distribution=str(distribution), bundle=str(app),
        manifest_sha256=sha(manifest_path), service=str(distribution / executable),
        service_sha256=files[executable], raw_binary=str(raw),
        bundle_info=str(app / "Contents/Info.plist"), bundle_info_sha256=files[f"{bundle_name}/Contents/Info.plist"],
        target=command[command.index("-target") + 1], minimum=info["LSMinimumSystemVersion"],
        build_manifest=str(distribution.parent / "native-build-result.json"),
        rust_manifest=str(run / RUST / "Cargo.toml"), rust_hashes=rust_hashes,
        boundary_library=str(boundary), boundary_sha256=sha(boundary),
        native_temporary_directory=str(native_temporary_directory),
        user_codex_directory=str(Path.home() / ".codex"),
    )


def group_script(group, plan, run):
    body = "\n".join(group["body"])
    if group['id'] == 171:
        prerequisite = 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not(not d["screenLocked"] and d["accessibility"]))'
        body = '''native_read_preflight="$CUA_REVIEW_RUN/t/native-read-171-preflight.json"
if "$CUA_REVIEW_LAUNCHER" --diagnostics > "$native_read_preflight" && ''' + shlex.join([sys.executable, '-c', prerequisite]) + ''' "$native_read_preflight"; then
    python3 test/review_settings_native_harness.py --manifest "$CUA_REVIEW_BUILD_MANIFEST" --output "$CUA_REVIEW_NATIVE_SETTINGS_BINARY" --results "$CUA_REVIEW_RUN/t/native-settings/run" || fail=1
else
    echo "Native read prerequisite unavailable: unlocked session and Accessibility are required" >&2
    fail=1
fi'''
    if group["id"] == 68:
        body = '''python3 test/review_xpc_harness.py --run || fail=1
(cd service && make xpc-session-admission-test) || fail=1'''
    if group_uses_native_ax_fixture(group):
        prerequisite = 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not(not d["screenLocked"] and d["accessibility"]))'
        body = '''native_read_preflight="$CUA_REVIEW_RUN/t/native-read-''' + str(group["id"]) + '''-preflight.json"
if "$CUA_REVIEW_LAUNCHER" --diagnostics > "$native_read_preflight" && ''' + shlex.join([sys.executable, "-c", prerequisite]) + ''' "$native_read_preflight"; then
    if test -x "$CUA_REVIEW_NATIVE_AX_BINARY" || python3 test/review_native_ax_harness.py --manifest "$CUA_REVIEW_BUILD_MANIFEST" --output "$CUA_REVIEW_NATIVE_AX_BINARY"; then
    CUA_NATIVE_READ_GROUP=''' + str(group["id"]) + ''' "$CUA_REVIEW_NATIVE_AX_BINARY" || fail=1
    else
        fail=1
    fi
else
    echo "Native read prerequisite unavailable: unlocked session and Accessibility are required" >&2
    fail=1
fi'''
    if "node test/lifecycle.mjs" in body:
        body += '''
mkdir -p "$CUA_REVIEW_RUN/t/native-lifecycle"
"$CUA_REVIEW_LAUNCHER" --native-target-stop-checks "$CUA_REVIEW_RUN/t/native-lifecycle/target-stop.json" "$CUA_REVIEW_RUN/t/native-lifecycle/fixtures" || fail=1
"$CUA_REVIEW_LAUNCHER" --native-frontmost-window-checks "$CUA_REVIEW_RUN/t/native-lifecycle/frontmost.json" || fail=1
"$CUA_REVIEW_LAUNCHER" --native-service-dispatch-checks "$CUA_REVIEW_RUN/t/native-lifecycle/dispatch.json" || fail=1'''
    if group_uses_desktop_fixture(group):
        diagnostic = 'import json,sys; d=json.load(sys.stdin); sys.exit(not(d["screenInteractionAvailable"] and d["accessibility"] and d["screenRecording"]))'
        coordinate = "node test/coordinates.mjs" in body
        tests = ["node test/coordinates.mjs"] if coordinate else [
            "node test/native-automation.mjs", "node test/native-web-form.mjs", "node test/native-hosted-panel.mjs",
            "node test/native-deep-hierarchy.mjs", "CUA_NATIVE_PRESS_ERROR_PROBE=1 node test/native-automation.mjs",
            "node test/native-url-policy-thread.mjs",
        ]
        test_commands = "\n".join(f"        {command} || fail=1" for command in tests)
        body = f'''if "$CUA_REVIEW_LAUNCHER" --diagnostics | {shlex.join([sys.executable, "-c", diagnostic])}; then
    if test -x "$CUA_REVIEW_DESKTOP_BINARY" || python3 test/build-native-automation-harness.py --review-desktop --output "$CUA_REVIEW_DESKTOP_BINARY"; then
{test_commands}
    else
        fail=1
    fi
else
    echo "The native desktop fixture requires an unlocked console with Accessibility and Screen Recording" >&2
    fail=1
fi'''
        if not coordinate:
            body += "\n(cd service && make element-validation-test) || fail=1"
    substitutions = {
        "(cd service && make selftest bundle)": (
            '("$CUA_REVIEW_LAUNCHER" --selftest && /usr/bin/codesign --verify --deep --strict '
            + shlex.quote(plan["bundle"]) + ")"
        ),
        "(cd service && make deployment-target-check)": shlex.join([
            "python3", "test/deployment-target.py", "--binary", plan["raw_binary"], "--bundle", plan["bundle"],
            "--target", plan["target"], "--minimum", plan["minimum"],
            "--output", str(run / "deployment-check.json"),
        ]),
        "(cd service && make screen-lock-state-test)": shlex.join([
            'python3','test/screen-lock-state.py','--manifest',plan['build_manifest'],
            '--artifacts',str(run/'t/session-state'),'--native']),
        "--manifest-path rust/cua-client/Cargo.toml": '--manifest-path "$CUA_REVIEW_RUST_MANIFEST"',
    }
    for old, new in substitutions.items():
        body = body.replace(old, new)
    return "set -uo pipefail\nfail=0\n" + body + "\nexit $fail\n"


def group_launches(run, group_id):
    launches = []
    for path in sorted((run / "launches").glob("*.json")):
        receipt = read(path)
        if receipt["group"] != str(group_id):
            continue
        trace = Path(receipt["owned_directory"]) / "boundary.jsonl"
        rows = [json.loads(line) for line in trace.read_text().splitlines()] if trace.is_file() else []
        started = any(r["kind"] == "boundary-installed" and r["pid"] == receipt["pid"] and
                      r["kernel_file_and_IP_network_isolation_installed"] for r in rows)
        stopped = any(r["kind"] == "ordinary-process-exit" for r in rows)
        launches.append(dict(**receipt, boundary_installed=started, exit_traced=stopped))
    return launches


def group_uses_service(group):
    body = "\n".join(group["body"])
    script_launchers = {"node": "serviceTestExecutable", "python3": "CUA_REVIEW_LAUNCHER"}
    return group["id"] == 68 or group_uses_desktop_fixture(group) or "make selftest bundle" in body or any(
        script_launchers[interpreter] in (PROJECT / file).read_text()
        for interpreter, file in re.findall(r"\b(node|python3)\s+(test/[\w-]+\.(?:mjs|py))", body)
    )


def group_uses_desktop_fixture(group):
    return any("make native-automation-test native-web-form-test" in line or "node test/coordinates.mjs" in line
               for line in group["body"])


def group_uses_native_ax_fixture(group):
    return group["id"] in (10, 21, 32, 42, 84, 91, 97)


def native_ax_receipt_matches(receipt, plan, binary):
    try:
        value = read(receipt)
        normal_file = Path(plan["build_manifest"])
        normal = read(normal_file)
        builder_spec = importlib.util.spec_from_file_location("native_read_builder", TEST / "review_native_ax_harness.py")
        builder = importlib.util.module_from_spec(builder_spec)
        builder_spec.loader.exec_module(builder)
        expected_sources = {str((PROJECT / name).resolve()): digest for name, digest in normal["source_hashes"].items()}
        expected_fixtures = {str(TEST / name) for name in [
            "event-stream-children-native.swift", "event-stream-tree-focus-native.swift",
            "event-stream-invalidation-monitor-native.swift", "event-stream-native-selection-records-native.swift",
            "event-stream-attributed-native.swift", "event-stream-snapshots-native.swift", "event-stream-context-native.swift"]}
        expected_generated_names = {"main.swift"} | {Path(name).name for name in expected_fixtures}
        return (value["build_terminal"] and value["build_exit_code"] == 0
                and value.get("key") == builder.build_key(normal_file)
                and value.get("groups") == [10, 21, 32, 42, 84, 91, 97]
                and value.get("compiled_Swift_inputs") == normal["swift_inputs"] + len(expected_fixtures)
                and value.get("signature_verified") is True
                and value["package_manifest_sha256"] == plan["manifest_sha256"]
                and value["native_build_manifest_sha256"] == sha(normal_file)
                and value["normal_source_hashes"] == expected_sources
                and set(value["fixture_source_hashes"]) == expected_fixtures
                and len(value["generated_source_hashes"]) == 8
                and {Path(name).name for name in value["generated_source_hashes"]} == expected_generated_names
                and sum(name.endswith(".swift") for name in value["compile_input_hashes"]) == normal["swift_inputs"] + len(expected_fixtures)
                and value["executable_sha256"] == sha(binary)
                and all(sha(Path(name)) == digest for field in
                        ["normal_source_hashes", "fixture_source_hashes", "compile_input_hashes", "generated_source_hashes"]
                        for name, digest in value[field].items()))
    except (OSError, KeyError, TypeError, ValueError):
        return False


def run_group(group, plan, run, env, timeout):
    start = time.monotonic()
    prefix = f"group-{group['id']:03d}"
    script = run / (prefix + ".sh")
    script.write_text(group_script(group, plan, run))
    logfile = run / (prefix + ".log")
    with logfile.open("w") as log, subprocess.Popen(
        ["/bin/bash", str(script)], cwd=PROJECT,
        env={**env, "CUA_REVIEW_GROUP": str(group["id"])},
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True
    ) as process:
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            timed_out = isinstance(error, subprocess.TimeoutExpired)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            if not timed_out:
                raise
    launches = group_launches(run, group["id"])
    uses_service = group_uses_service(group) or group_uses_native_ax_fixture(group) or group['id'] == 171
    passed = (process.returncode == 0 and not timed_out and (launches or not uses_service)
              and all(r["boundary_installed"] and r["exit_traced"] for r in launches))
    native_ax_receipt = None
    native_read_prerequisite_unavailable = False
    if group_uses_native_ax_fixture(group):
        receipt = Path(env["CUA_REVIEW_NATIVE_AX_BINARY"]).parent / "build-result.json"
        native_ax_receipt = str(receipt)
        passed = (passed and native_ax_receipt_matches(receipt, plan, Path(env["CUA_REVIEW_NATIVE_AX_BINARY"])))
        try:
            state = read(run / "t" / f"native-read-{group['id']}-preflight.json")
            if isinstance(state.get("screenLocked"), bool) and isinstance(state.get("accessibility"), bool):
                native_read_prerequisite_unavailable = state["screenLocked"] or not state["accessibility"]
        except (OSError, ValueError, TypeError):
            pass
    status = "passed" if passed else "blocked_prerequisite" if native_read_prerequisite_unavailable else "failed"
    selected_xpc_receipt = None
    selected_settings_receipt = None
    if group['id'] == 171:
        import review_settings_native_harness
        binary = Path(env['CUA_REVIEW_NATIVE_SETTINGS_BINARY'])
        selected_settings_receipt = str(binary.parent / 'build-result.json')
        passed = passed and review_settings_native_harness.valid_receipt(Path(plan['build_manifest']), binary)
        try:
            state = read(run / 't/native-read-171-preflight.json')
            native_read_prerequisite_unavailable = state['screenLocked'] or not state['accessibility']
        except (OSError, ValueError, KeyError, TypeError):
            pass
        status = 'passed' if passed else 'blocked_prerequisite' if native_read_prerequisite_unavailable else 'failed'
    if group["id"] == 68:
        import review_xpc_harness
        binary = run / "t/xpc/AexComputerUseService"
        selected_xpc_receipt = str(binary.parent / "build-result.json")
        passed = passed and review_xpc_harness.validate_receipt(plan, binary)
        status = "passed" if passed else "failed"
    label = "PASS" if passed else "BLOCKED" if native_read_prerequisite_unavailable else "FAIL"
    print(f"{label} {group['id']:03d} {group['name']} ({time.monotonic()-start:.1f}s)", flush=True)
    if not passed:
        print(logfile.read_text()[-3000:], flush=True)
    return dict(id=group["id"], name=group["name"], passed=bool(passed), status=status, exit_code=process.returncode,
                native_read_prerequisite_unavailable=native_read_prerequisite_unavailable,
                timed_out=timed_out, elapsed_seconds=time.monotonic()-start, launches=launches,
                requires_selected_service=uses_service,
                selected_native_ax_build_receipt=native_ax_receipt,
                selected_XPC_build_receipt=selected_xpc_receipt,
                selected_native_settings_build_receipt=selected_settings_receipt,
                log=str(logfile), script_sha256=sha(script))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, nargs="?")
    parser.add_argument("--list", action="store_true", help="list the groups without running them")
    parser.add_argument("--group", type=int, action="append", help="run this group number, repeat to select several")
    parser.add_argument("--native-ax-binary", type=Path, help="reuse an owned native AX build after verifying its source and package receipt")
    parser.add_argument("--native-settings-binary", type=Path, help="reuse a hidden native Settings build after verifying its source and package receipt")
    parser.add_argument("--timeout", type=float, default=600, help="timeout in seconds per group")
    args = parser.parse_args()
    groups = suite_groups()
    if args.list:
        for group in groups:
            print(f"{group['id']:03d} {group['name']}")
        return 0
    if not args.package or args.timeout <= 0:
        parser.error("provide the review package directory and a positive timeout")
    chosen = set(args.group or (group["id"] for group in groups))
    if chosen - {group["id"] for group in groups}:
        parser.error("unknown group number")
    run = Path(tempfile.mkdtemp(prefix="cua-rv-", dir="/private/tmp"))
    print(f"Review suite artifacts: {run}", flush=True)
    (run / "launches").mkdir()
    (run / "t").mkdir()
    plan = verify_package(args.package.resolve(strict=True), run)
    native_ax_binary = (args.native_ax_binary.resolve(strict=True) if args.native_ax_binary
                        else run / "t/native-ax/AexComputerUseService")
    if args.native_ax_binary and not native_ax_receipt_matches(native_ax_binary.parent / "build-result.json", plan, native_ax_binary):
        raise SystemExit("The prepared native AX executable no longer matches this package or its recorded sources")
    native_settings_binary = (args.native_settings_binary.resolve(strict=True) if args.native_settings_binary
                              else run / 't/native-settings/AexComputerUseService')
    if args.native_settings_binary:
        import review_settings_native_harness
        if not review_settings_native_harness.valid_receipt(Path(plan['build_manifest']), native_settings_binary):
            raise SystemExit('The prepared native Settings executable no longer matches its package and sources')
    plan['native_settings_binary'] = str(native_settings_binary)
    write(run / "artifacts.json", plan)
    launcher = run / "service"
    desktop_launcher = run / "desktop"
    for target, source in ((launcher, "review-service-launch.py"), (desktop_launcher, "review-desktop-launch.py")):
        target.write_text("#!/bin/sh\nexec " + shlex.join([sys.executable, str(TEST / source)]) + ' "$@"\n')
        target.chmod(0o700)
    env = os.environ.copy()
    env.pop("CODEX_HOME", None)
    env.pop("CARGO_TARGET_DIR", None)
    env.pop("CODEX_CLI_PATH", None)
    env.update(CUA_REVIEW_RUN=str(run), CUA_REVIEW_LAUNCHER=str(launcher),
               CUA_REVIEW_RUST_MANIFEST=plan["rust_manifest"], CUA_REVIEW_BUILD_MANIFEST=plan["build_manifest"],
               CUA_REVIEW_DESKTOP_LAUNCHER=str(desktop_launcher), CUA_REVIEW_DESKTOP_BINARY=str(run / "t/desktop/AexComputerUseService"),
               CUA_REVIEW_NATIVE_AX_BINARY=str(native_ax_binary),
               CUA_REVIEW_NATIVE_SETTINGS_BINARY=str(native_settings_binary),
               CUA_CODEC_BOUNDARY_HARNESS=str(run / "t/codec/AexComputerUseService"),
               CUA_CODEC_BOUNDARY_REPORT=str(run / "codec-requests.json"),
               CUA_SOCKET_DISPATCH_REPORT=str(run / "codec-dispatch.json"),
               CUA_SOCKET_RESPONSE_REPORT=str(run / "codec-responses.json"), TMPDIR=str(run / "t"))
    diagnostic = subprocess.check_output([str(launcher), "--diagnostics"], cwd=PROJECT,
                                         env={**env, "CUA_REVIEW_GROUP": "preflight"}, text=True, timeout=20)
    write(run / "diagnostics.json", json.loads(diagnostic))
    preflight = group_launches(run, "preflight")
    if len(preflight) != 1 or not preflight[0]["boundary_installed"] or not preflight[0]["exit_traced"]:
        raise SystemExit("The signed package did not load the isolated startup boundary")
    result = dict(revision=plan["revision"], service_sha256=plan["service_sha256"],
                  total_groups=len(groups), groups=[], selected=sorted(chosen), full_suite_passed=False)
    for group in groups:
        if group["id"] in chosen:
            result["groups"].append(run_group(group, plan, run, env, args.timeout))
            write(run / "result.json", result)
    if any(sha(run / name) != digest for name, digest in plan["rust_hashes"].items()):
        raise SystemExit("The Rust crate changed while running the tests")
    passed = sum(group["passed"] for group in result["groups"])
    result["full_suite_passed"] = passed == len(groups)
    write(run / "result.json", result)
    print(f"{passed}/{len(chosen)} selected groups passed out of {len(groups)} in the suite. Report: {run / 'result.json'}")
    return 0 if passed == len(chosen) else 1


if __name__ == "__main__":
    sys.exit(main())
