"""Checks the shipped bundle's signature on a built package.

  - the service, client and guardian bundles carry the hardened runtime, a secure
    timestamp (unless ad-hoc) and exactly the entitlements bundle_signing expects;
  - every bundle reports the product version;
  - the shipped service ignores DYLD_INSERT_LIBRARIES (checked only where System
    Integrity Protection is on, since macOS enforces it only then), while the copy the review
    suite re-signs for its startup boundary loads the same library (the control
    that proves the library itself works).
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "service"))
import bundle_signing as signing

MARKER_SOURCE = r'''
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
__attribute__((constructor)) static void write_injection_marker(void) {
    const char *path = getenv("CUA_INJECTION_MARKER");
    if (path == NULL) return;
    int descriptor = open(path, O_CREAT | O_WRONLY, 0600);
    if (descriptor >= 0) close(descriptor);
}
'''

failures = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f": {detail}" if detail and not condition else ""), flush=True)
    if not condition:
        failures.append(name)


def signature(bundle):
    return subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(bundle)],
                          check=True, capture_output=True, text=True).stderr


def expected_entitlements(role, group):
    if role == "service":
        return signing.service_entitlements(group)
    if role == "client":
        return signing.client_entitlements(group)
    return signing.guardian_entitlements()


def check_bundles(app):
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature(app), re.MULTILINE)
    group = team.group(1) + ".com.aex.computeruse" if team else None
    identity = signing.certificate_identity(app)
    version = signing.product_version()
    roles = {"service": app,
             "client": app / "Contents/SharedSupport/AexComputerUseClient.app",
             "guardian": app / "Contents/SharedSupport/AexLockScreenGuardian.app"}
    for role, bundle in roles.items():
        details = signature(bundle)
        flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", details)
        check(f"{role}: hardened runtime", flags is not None and "runtime" in flags.group(1).split(","),
              flags.group(0) if flags else "no CodeDirectory flags")
        if identity != signing.AD_HOC_IDENTITY:
            check(f"{role}: secure timestamp", re.search(r"^Timestamp=", details, re.MULTILINE) is not None,
                  "signed without a secure timestamp")
        entitlements = signing.signed_entitlements(bundle)
        check(f"{role}: entitlements", entitlements == expected_entitlements(role, group), entitlements)
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        check(f"{role}: version {version}",
              info.get("CFBundleShortVersionString") == version and info.get("CFBundleVersion") == version, info)


def system_integrity_protection_enabled():
    status = subprocess.run(["/usr/bin/csrutil", "status"], capture_output=True, text=True).stdout
    return "status: enabled" in status


def injection_marker_written(executable, library, directory):
    marker = directory / (executable.parent.parent.parent.name + ".marker")
    marker.unlink(missing_ok=True)
    environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR=str(directory),
                       DYLD_INSERT_LIBRARIES=str(library), CUA_INJECTION_MARKER=str(marker))
    subprocess.run([str(executable), "--diagnostics"], env=environment, capture_output=True, timeout=30)
    return marker.exists()


def check_injection(app, directory):
    identity = signing.certificate_identity(app)
    library = directory / "injection-marker.dylib"
    source = directory / "injection-marker.c"
    source.write_text(MARKER_SOURCE)
    subprocess.run(["/usr/bin/clang", "-dynamiclib", "-o", str(library), str(source)], check=True)
    # Signed by the bundle's own certificate, so library validation alone
    # cannot be what keeps it out of the shipped service.
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", str(library)],
                   check=True, capture_output=True)
    executable = app / "Contents/MacOS/AexComputerUseService"
    if system_integrity_protection_enabled():
        check("shipped service ignores DYLD_INSERT_LIBRARIES",
              not injection_marker_written(executable, library, directory))
    else:
        # Without SIP, AMFI does not enforce the hardened runtime's DYLD
        # restriction, so the injection would load here whatever the signature says.
        print("SKIP shipped service ignores DYLD_INSERT_LIBRARIES: System Integrity Protection is disabled "
              "on this Mac, so macOS does not enforce the restriction (the runtime flag is checked above)", flush=True)
    tested = signing.resign_copy_for_tests(app, directory / "signed-for-tests" / app.name)
    check("re-signed test copy loads the same library (control)",
          injection_marker_written(tested / "Contents/MacOS/AexComputerUseService", library, directory))
    check("re-signed test copy keeps the certificate", signing.certificate_identity(tested) == identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default = os.environ.get("CUA_REVIEW_BUNDLE", str(PROJECT / "service/.build/current/dist/AexComputerUseService.app"))
    parser.add_argument("--bundle", default=default)
    app = Path(parser.parse_args().bundle).resolve(strict=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    check_bundles(app)
    with tempfile.TemporaryDirectory(prefix="cua-release-signature-") as temporary:
        check_injection(app, Path(temporary))
    print(f"{'ALL RELEASE SIGNATURE CHECKS PASSED' if not failures else f'{len(failures)} release signature checks failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
