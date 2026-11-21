"""Launch a review codec fixture with owned files and a real local peer."""

from pathlib import Path
import hashlib
import json
import os
import subprocess


def launch(binary, endpoint, env, log):
    argv = [str(binary), endpoint]
    if run := env.get("CUA_REVIEW_RUN"):
        owned = Path(run).resolve(strict=True)
        socket_directory = Path(endpoint).parent.resolve(strict=True)
        binary = binary.resolve(strict=True)
        if not socket_directory.is_relative_to(owned / "t") or not binary.is_relative_to(owned / "t"):
            raise ValueError("Review codec fixture and endpoint must be inside the test run")
        manifest = json.loads((binary.parent / "build-result.json").read_text())
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest["binary_sha256"]:
            raise ValueError("Review codec fixture does not match its build receipt")
        profile = socket_directory / "owned-codec.sb"
        profile.write_text(
            "(version 1)\n(allow default)\n(deny appleevent-send)\n(deny network-outbound (remote ip))\n"
            "(deny file-write*)\n"
            f"(allow file-write* (subpath {json.dumps(str(socket_directory))}) (literal \"/dev/null\"))\n"
            f"(deny file-read-data (subpath {json.dumps(str(Path.home() / '.codex'))}))\n"
        )
        env = {key: value for key, value in env.items() if not key.startswith("DYLD_") and key != "CODEX_HOME"}
        argv = ["/usr/bin/sandbox-exec", "-f", str(profile), str(binary), "--owned-codec-socket", endpoint]
    return subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=log)


def artifact_path(variable, default):
    return Path(os.environ.get(variable, default))
