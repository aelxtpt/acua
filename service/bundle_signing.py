"""Code-signing choices for the shipped bundle, shared by the build and the review suite."""

import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

SERVICE = Path(__file__).resolve().parent
VERSION_FILE = SERVICE / "VERSION"
CODESIGN = "/usr/bin/codesign"
AD_HOC_IDENTITY = "-"

APPLE_EVENTS = "com.apple.security.automation.apple-events"
CALENDARS = "com.apple.security.personal-information.calendars"
ADDRESS_BOOK = "com.apple.security.personal-information.addressbook"
APPLICATION_GROUPS = "com.apple.security.application-groups"
DYLD_ENVIRONMENT = "com.apple.security.cs.allow-dyld-environment-variables"


def signing_options(identity):
    # Apple's timestamp service only countersigns certificate-backed signatures.
    timestamp = "--timestamp=none" if identity == AD_HOC_IDENTITY else "--timestamp"
    return ["--options", "runtime", timestamp]


def service_entitlements(group):
    # Under the hardened runtime these resources need an entitlement even after
    # the user grants them: Messages delivery sends Apple Events, the calendar
    # tools use EventKit and Messages recipients use Contacts.
    entitlements = {APPLE_EVENTS: True, CALENDARS: True, ADDRESS_BOOK: True}
    if group:
        entitlements[APPLICATION_GROUPS] = [group]
    return entitlements


def client_entitlements(group):
    # The client reports turn ends to the service with Apple Events.
    entitlements = {APPLE_EVENTS: True}
    if group:
        entitlements[APPLICATION_GROUPS] = [group]
    return entitlements


def guardian_entitlements():
    return {}


def test_entitlements(shipped):
    # Only the review suite's own copy accepts DYLD_INSERT_LIBRARIES, which it
    # needs to load its isolated startup boundary. The shipped bundle never does.
    return {**shipped, DYLD_ENVIRONMENT: True}


def product_version():
    return VERSION_FILE.read_text().strip()


def versioned_info(info, version):
    return {**info, "CFBundleShortVersionString": version, "CFBundleVersion": version}


def signed_entitlements(bundle):
    output = subprocess.run([CODESIGN, "--display", "--entitlements", "-", "--xml", str(bundle)],
                            check=True, capture_output=True).stdout
    return plistlib.loads(output) if output.strip() else {}


def certificate_identity(bundle):
    """SHA-1 of the leaf signing certificate, which codesign accepts as an identity."""
    with tempfile.TemporaryDirectory(prefix="cua-certificates-") as directory:
        subprocess.run([CODESIGN, "--display", "--extract-certificates=" + directory + "/leaf", str(bundle)],
                       check=True, capture_output=True)
        leaf = Path(directory) / "leaf0"
        if not leaf.exists():
            return AD_HOC_IDENTITY
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()


def resign_copy_for_tests(bundle, destination):
    """Copies the bundle and re-signs only its outer service with the test entitlements.

    The code and the certificate stay the same, so the macOS privacy grants
    made for the shipped bundle still apply to the copy.
    """
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, destination, symlinks=True)
    entitlements = destination.parent / (destination.name + ".entitlements.plist")
    entitlements.write_bytes(plistlib.dumps(test_entitlements(signed_entitlements(bundle))))
    identity = certificate_identity(bundle)
    subprocess.run([CODESIGN, "--force", "--sign", identity, "--options", "runtime", "--timestamp=none",
                    "--entitlements", str(entitlements), str(destination)], check=True, capture_output=True)
    subprocess.run([CODESIGN, "--verify", "--deep", "--strict", str(destination)], check=True, capture_output=True)
    return destination
