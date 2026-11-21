"""Launch the review desktop test executable inside its fixture directory."""

import hashlib
import json
import os
from pathlib import Path
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    run = Path(os.environ["CUA_REVIEW_RUN"]).resolve(strict=True)
    if len(sys.argv) != 2:
        raise SystemExit("Pass one new socket path in the desktop fixture directory")
    socket = Path(sys.argv[1])
    directory = socket.parent.resolve(strict=True)
    if not socket.is_absolute() or not directory.is_relative_to(run / "t") or socket.exists() or socket.is_symlink():
        raise SystemExit("Pass one new socket path in the desktop fixture directory")
    plan = json.loads((run / "artifacts.json").read_text())
    binary = run / "t/desktop/AexComputerUseService"
    receipt = json.loads((binary.parent / "build-result.json").read_text())
    if (receipt["startup"] != "owned desktop socket only" or sha(binary) != receipt["binary_sha256"] or
            sha(Path(plan["build_manifest"])) != receipt["selected_manifest_sha256"]):
        raise SystemExit("The desktop fixture is not the selected review build")

    shots = directory / "shots"
    shots.mkdir(exist_ok=True)
    if shots.is_symlink():
        raise SystemExit("The fixture screenshots require an owned directory")
    profile = directory / "owned-desktop.sb"
    profile.write_text(
        "(version 1)\n(allow default)\n(deny appleevent-send)\n(deny network-outbound (remote ip))\n"
        "(deny file-write*)\n"
        f'(allow file-write* (subpath {json.dumps(str(directory))}) (literal "/dev/null"))\n'
        f'(deny file-read-data (subpath {json.dumps(plan["user_codex_directory"])}))\n'
    )
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("DYLD_") and key not in {"CODEX_HOME", "CODEX_CLI_PATH", "ACUA_SERVICE_PROMPT_PERMISSIONS"}}
    env.update(ACUA_SCREENSHOT_DIRECTORY=str(shots),
               ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS="1")
    os.execve("/usr/bin/sandbox-exec", ["/usr/bin/sandbox-exec", "-f", str(profile), str(binary),
                                      "--owned-desktop-socket", str(socket)], env)


if __name__ == "__main__":
    main()
