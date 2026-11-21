"""Launch the selected signed service with the existing isolated startup boundary."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


def owned_path(value, directory):
    path = Path(value).resolve()
    if not path.is_relative_to(directory):
        raise SystemExit(f"Fixture path is outside the review run: {path}")
    return path


def main():
    run = Path(os.environ["CUA_REVIEW_RUN"]).resolve(strict=True)
    plan = json.loads((run / "artifacts.json").read_text())
    service = Path(plan["service"])
    for key in ("service", "bundle_info", "boundary_library"):
        digest_key = "boundary_sha256" if key == "boundary_library" else f"{key}_sha256"
        if hashlib.sha256(Path(plan[key]).read_bytes()).hexdigest() != plan[digest_key]:
            raise SystemExit(f"The selected {key} changed after preflight")
    args = sys.argv[1:]
    diagnostic = args in (["--selftest"], ["--diagnostics"])
    # Flag -> argument count including the flag. Every path argument must be inside the run.
    owned_diagnostics = {"--native-target-stop-checks": 3, "--native-frontmost-window-checks": 2,
                         "--native-launch-state-checks": 2, "--native-legacy-offscreen-checks": 3,
                         "--native-request-controller-executor-window": 2,
                         "--native-service-dispatch-checks": 2,
                         "--native-refetch-only-checks": 2, "--native-string-writer-checks": 2,
                         "--native-field-operation-checks": 2, "--native-secondary-scroll-checks": 2,
                         "--native-selection-checks": 2, "--native-pasteboard-checks": 2,
                         "--native-coordinate-checks": 3, "--native-element-click-corrections": 2,
                         "--native-app-snapshot-request-checks": 3, "--native-action-request-checks": 2,
                         "--native-coordinator-error-checks": 2, "--native-screenshot-file-checks": 2,
                         "--native-screenshot-buffer-checks": 2, "--native-error-codec-checks": 3,
                         "--native-error-classification-checks": 3, "--native-lock-preparation-checks": 3,
                         "--native-default-policy": 2}
    if args and args[0] in owned_diagnostics:
        if len(args) != owned_diagnostics[args[0]]:
            raise SystemExit("The native diagnostic requires its output paths")
        for value in args[1:]:
            owned_path(value, run)
        diagnostic = True
    if not diagnostic:
        if len(args) != 1 or not Path(args[0]).is_absolute():
            raise SystemExit("Pass an absolute socket path in the review run")
        socket = owned_path(args[0], run)
        if not socket.parent.is_dir() or Path(args[0]).is_symlink() or socket.exists():
            raise SystemExit("The review service requires a new socket in an owned directory")

    env = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
    # Some tests specify a disposable Codex configuration directory. Route it
    # through the owned home mapping, then remove the inherited override.
    fixture = env.pop("CODEX_HOME", None)
    env.pop("ACUA_SERVICE_PROMPT_PERMISSIONS", None)

    owned = Path(tempfile.mkdtemp(prefix="cua-review-startup-", dir="/private/tmp"))
    fixture_home = owned / "home"
    fixture_home.mkdir()
    config = fixture_home / ".codex"
    if fixture:
        directory = owned_path(fixture, run)
        directory.mkdir(parents=True, exist_ok=True)
        config.symlink_to(directory, target_is_directory=True)
    else:
        config.mkdir()
    (owned / "container").mkdir()
    quoted = json.dumps
    profile = (
        "(version 1)\n(allow default)\n(deny appleevent-send)\n(deny network-outbound (remote ip))\n"
        "(deny file-write*)\n"
        f"(allow file-write* (subpath {quoted(str(owned))}) (subpath {quoted(str(run))}) "
        f"(subpath {quoted(plan['native_temporary_directory'])}) (literal \"/dev/null\"))\n"
        f"(deny file-read-data (subpath {quoted(plan['user_codex_directory'])}))\n"
    )
    (owned / "owned-startup.sb").write_text(profile)
    env.update(CUA_OWNED_STARTUP_DIRECTORY=str(owned), DYLD_INSERT_LIBRARIES=plan["boundary_library"])
    receipt = dict(pid=os.getpid(), group=env["CUA_REVIEW_GROUP"], args=args, owned_directory=str(owned),
                   service_sha256=plan["service_sha256"], strict_authentication=
                   env.get("ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS") != "1", diagnostic=diagnostic)
    (run / "launches" / f"{os.getpid()}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    os.execve(service, [str(service), *args], env)


if __name__ == "__main__":
    main()
