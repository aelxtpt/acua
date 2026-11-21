"""Install the complete Aex Computer Use application without launching it."""

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

IDENTIFIER = "com.aex.computeruse"
APP_NAME = "Aex Computer Use.app"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_identifier(path):
    try:
        return plistlib.loads((path / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def verify_signature(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, text=True)


def verify_files(root, expected):
    actual = {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() or p.is_symlink()}
    if actual != set(expected):
        raise ValueError("The application contains missing or unlisted files")
    for name, digest in expected.items():
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or sha(path) != digest:
            raise ValueError(f"The application does not match its build manifest: {name}")


def swap_directories(first, second):
    # Public macOS renameatx_np, sys/stdio.h: RENAME_SWAP = 0x00000002.
    # The live path remains present during replacement; failure keeps it intact.
    function = ctypes.CDLL(None, use_errno=True).renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(-2, os.fsencode(first), -2, os.fsencode(second), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(second))


def install(distribution, destination):
    distribution = Path(distribution).resolve(strict=True)
    destination = Path(destination).expanduser().resolve()
    manifest = json.loads((distribution.parent / "package-build-result.json").read_text())
    name = manifest.get("app_bundle", APP_NAME)
    if Path(name).name != name or not name.endswith(".app"):
        raise ValueError("The package requires an application bundle name")
    source = distribution / name
    prefix = name + "/"
    files = {name[len(prefix):]: digest for name, digest in manifest["files"].items() if name.startswith(prefix)}
    if not files or bundle_identifier(source) != IDENTIFIER:
        raise ValueError("Select a built Aex Computer Use application")
    verify_files(source, files)
    verify_signature(source)
    parent = destination / "computer-use"
    if not parent.resolve().is_relative_to(destination):
        raise ValueError("The computer-use directory escapes the selected destination")
    target = parent / APP_NAME
    # Catch an accidental attempt to install a package over itself.
    if source == target.resolve() or destination.is_relative_to(distribution):
        raise ValueError("The destination overlaps the source application")
    receipt = dict(app=str(target), distribution=str(distribution),
                   package_manifest_sha256=sha(distribution.parent / "package-build-result.json"),
                   files=len(files), launched=False)
    parent.mkdir(parents=True, exist_ok=True)
    with (parent / ".acua-install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.is_symlink() or (target.exists() and bundle_identifier(target) != IDENTIFIER):
            raise ValueError("The existing application is not the Aex Computer Use service")
        if target.exists():
            try:
                verify_files(target, files)
                verify_signature(target)
            except (ValueError, subprocess.CalledProcessError):
                pass
            else:
                return dict(**receipt, updated=False)
        with tempfile.TemporaryDirectory(prefix=".acua-install-", dir=parent) as temporary:
            staged = Path(temporary) / APP_NAME
            shutil.copytree(source, staged, symlinks=True)
            verify_files(staged, files)
            verify_signature(staged)
            # Verify the source again so a concurrent build cannot silently
            # change the inputs during copying.
            verify_files(source, files)
            if target.exists():
                swap_directories(staged, target)
            else:
                os.replace(staged, target)
        return dict(**receipt, updated=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--distribution", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    result = install(args.distribution, args.destination)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
