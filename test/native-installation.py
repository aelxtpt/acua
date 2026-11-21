"""Exercise complete installation and replacement in owned temporary directories."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cua_install_native", PROJECT / "service/install_native.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def main():
    run = Path(tempfile.mkdtemp(prefix="cua-install-", dir="/private/tmp"))
    print(run, flush=True)
    root = run / "owned destination ç"
    root.mkdir()
    (root / "config.toml").write_text('# owned configuration\nmodel = "unchanged"\n')
    (root / "IPC").mkdir()
    (root / "IPC/owned-data").write_text("preserve")
    command = ["make", "-C", str(PROJECT / "service"), "install", f"SERVICE_DIR={root}",
               "CODESIGN_IDENTITY=" + os.environ.get("CODESIGN_IDENTITY", "-")]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    (run / "make-install.log").write_text(result.stdout + result.stderr)
    cases = []
    def check(name, condition):
        cases.append(dict(name=name, passed=bool(condition)))
    check("normal make install completes", result.returncode == 0)
    if result.returncode:
        raise RuntimeError(result.stderr)
    # make may publish a new signed generation. Verify the exact immutable
    # generation reported by the installer, rather than a pre-build snapshot.
    install_receipt = json.JSONDecoder().raw_decode(result.stdout[result.stdout.rindex("{"):])[0]
    distribution = Path(install_receipt["distribution"])
    manifest = json.loads((distribution.parent / "package-build-result.json").read_text())
    prefix = manifest["app_bundle"] + "/"
    expected = {name[len(prefix):]: digest for name, digest in manifest["files"].items() if name.startswith(prefix)}
    app = root / "computer-use" / installer.APP_NAME
    installer.verify_files(app, expected)
    installer.verify_signature(app)
    check("installed application is an exact complete signed copy", True)
    check("client and guardian are executable", all(os.access(app / path, os.X_OK) for path in (
        "Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient",
        "Contents/SharedSupport/AexLockScreenGuardian.app/Contents/MacOS/AexLockScreenGuardian")))
    check("cursor artwork and dependency licenses are installed", all((app / path).is_file() for path in (
        "Contents/Resources/SoftwareCursor.png", "Contents/Resources/Licenses/swift-toml-LICENSE.md",
        "Contents/SharedSupport/AexComputerUseClient.app/Contents/Resources/Licenses/swift-argument-parser-LICENSE.txt")))
    inode = app.stat().st_ino
    repeated = installer.install(distribution, root)
    check("identical reinstall leaves the live application intact", not repeated["updated"] and app.stat().st_ino == inode)
    obsolete = app / "obsolete-owned-file"
    obsolete.write_text("old generation")
    before = {str(p.relative_to(app)): installer.sha(p) for p in app.rglob("*") if p.is_file()}
    def unchanged():
        return before == {str(p.relative_to(app)): installer.sha(p) for p in app.rglob("*") if p.is_file()}
    with patch.object(installer.shutil, "copytree", side_effect=OSError("owned copy failure")):
        try:
            installer.install(distribution, root)
        except OSError:
            check("copy failure preserves previous application", unchanged())
        else:
            check("copy failure preserves previous application", False)
    with patch.object(installer, "swap_directories", side_effect=OSError("owned swap failure")):
        try:
            installer.install(distribution, root)
        except OSError:
            check("publication failure preserves previous application", unchanged())
        else:
            check("publication failure preserves previous application", False)
    samples = []
    finished = threading.Event()
    def observe():
        while not finished.is_set():
            samples.append(app.is_dir())
            finished.wait(0.0005)
    observer = threading.Thread(target=observe)
    observer.start()
    try:
        update = installer.install(distribution, root)
    finally:
        finished.set()
        observer.join()
    installer.verify_files(app, expected)
    check("replacement removes stale files and publishes the exact package", update["updated"] and not obsolete.exists())
    check("application path stays present throughout replacement", samples and all(samples))
    check("temporary generations are cleaned after success and failure", not list(app.parent.glob(".acua-install-*")))
    check("configuration and unrelated legacy data remain intact", (root / "config.toml").read_text() == '# owned configuration\nmodel = "unchanged"\n' and (root / "IPC/owned-data").read_text() == "preserve")
    bad = run / "foreign/computer-use" / installer.APP_NAME
    (bad / "Contents").mkdir(parents=True)
    (bad / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="local.cua.unrelated")))
    try:
        installer.install(distribution, run / "foreign")
    except ValueError:
        check("unrelated application cannot be overwritten", installer.bundle_identifier(bad) == "local.cua.unrelated")
    else:
        check("unrelated application cannot be overwritten", False)
    linked_root = run / "linked"
    linked_root.mkdir()
    (linked_root / "computer-use").symlink_to(root / "computer-use", target_is_directory=True)
    try:
        installer.install(distribution, linked_root)
    except ValueError:
        check("destination directory cannot escape through a symlink", True)
    else:
        check("destination directory cannot escape through a symlink", False)
    linked_app = run / "linked-app/computer-use" / installer.APP_NAME
    linked_app.parent.mkdir(parents=True)
    linked_app.symlink_to(app, target_is_directory=True)
    try:
        installer.install(distribution, run / "linked-app")
    except ValueError:
        check("existing application symlink cannot redirect replacement", linked_app.is_symlink())
    else:
        check("existing application symlink cannot redirect replacement", False)
    try:
        installer.install(distribution, distribution)
    except ValueError:
        check("immutable package cannot be used as an installation destination", not (distribution / "computer-use").exists())
    else:
        check("immutable package cannot be used as an installation destination", False)
    corrupt = run / "corrupt/dist"
    corrupt.mkdir(parents=True)
    shutil.copy2(distribution.parent / "package-build-result.json", corrupt.parent / "package-build-result.json")
    copied = corrupt / manifest["app_bundle"]
    shutil.copytree(distribution / manifest["app_bundle"], copied)
    (copied / "Contents/Resources/SoftwareCursor.png").write_bytes(b"owned invalid payload")
    try:
        installer.install(corrupt, run / "rejected")
    except ValueError:
        check("tampered package is rejected before destination creation", not (run / "rejected").exists())
    else:
        check("tampered package is rejected before destination creation", False)
    helper = app / "Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient"
    help_result = subprocess.run([str(helper), "--help"], capture_output=True, text=True, timeout=15)
    check("installed client runs its real command parser", help_result.returncode == 0 and "turn-ended" in help_result.stdout)
    (run / "client-help.log").write_text(help_result.stdout + help_result.stderr)
    value = dict(passed=all(row["passed"] for row in cases), cases=cases, command=command,
                 command_exit_code=result.returncode, distribution=str(distribution), installed_app=str(app),
                 installed_files=len(expected), source_package_sha256=installer.sha(distribution.parent / "package-build-result.json"),
                 source_hashes={str(p.relative_to(PROJECT)): installer.sha(p) for p in
                     (PROJECT / "service/install_native.py", PROJECT / "service/Makefile", Path(__file__).resolve())},
                 replacement_presence_samples=len(samples), user_configuration_modified=False,
                 service_or_guardian_launched=False, physical_input_executed=False)
    (run / "result.json").write_text(json.dumps(value, indent=2) + "\n")
    print(f"{sum(row['passed'] for row in cases)}/{len(cases)} installation checks passed: {run / 'result.json'}", flush=True)
    return 0 if value["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
