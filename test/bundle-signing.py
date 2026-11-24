"""Unit tests for the shipped bundle's signing choices (service/bundle_signing.py)."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "service"))
import bundle_signing as signing

GROUP = "KS98C89L5H.com.aex.computeruse"
failures = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f": {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def SigningOptions_DeveloperIdentity_EnablesRuntimeAndSecureTimestamp():
    options = signing.signing_options("63C9A57EEB695B479240F1F251424F467D206F69")
    check("SigningOptions_DeveloperIdentity_EnablesRuntimeAndSecureTimestamp",
          options == ["--options", "runtime", "--timestamp"], options)


def SigningOptions_AdHocIdentity_EnablesRuntimeWithoutTimestamp():
    options = signing.signing_options("-")
    check("SigningOptions_AdHocIdentity_EnablesRuntimeWithoutTimestamp",
          options == ["--options", "runtime", "--timestamp=none"], options)


def ServiceEntitlements_SignedByTeam_AllowsAppleEventsCalendarsContactsAndGroup():
    entitlements = signing.service_entitlements(GROUP)
    check("ServiceEntitlements_SignedByTeam_AllowsAppleEventsCalendarsContactsAndGroup", entitlements == {
        "com.apple.security.automation.apple-events": True,
        "com.apple.security.personal-information.calendars": True,
        "com.apple.security.personal-information.addressbook": True,
        "com.apple.security.application-groups": [GROUP],
    }, entitlements)


def ServiceEntitlements_AdHoc_OmitsApplicationGroup():
    entitlements = signing.service_entitlements(None)
    check("ServiceEntitlements_AdHoc_OmitsApplicationGroup",
          "com.apple.security.application-groups" not in entitlements
          and entitlements.get("com.apple.security.automation.apple-events") is True, entitlements)


def ClientEntitlements_SignedByTeam_AllowsAppleEventsAndGroupOnly():
    entitlements = signing.client_entitlements(GROUP)
    check("ClientEntitlements_SignedByTeam_AllowsAppleEventsAndGroupOnly", entitlements == {
        "com.apple.security.automation.apple-events": True,
        "com.apple.security.application-groups": [GROUP],
    }, entitlements)


def ShippedEntitlements_AnyRole_NeverAllowInjectionOrUnsignedCode():
    # These exceptions would let any local process load code into an app
    # that holds Accessibility and Screen Recording.
    forbidden = {"com.apple.security.cs.allow-dyld-environment-variables",
                 "com.apple.security.cs.disable-library-validation",
                 "com.apple.security.cs.allow-unsigned-executable-memory",
                 "com.apple.security.get-task-allow"}
    shipped = [signing.service_entitlements(GROUP), signing.service_entitlements(None),
               signing.client_entitlements(GROUP), signing.client_entitlements(None),
               signing.guardian_entitlements()]
    check("ShippedEntitlements_AnyRole_NeverAllowInjectionOrUnsignedCode",
          not any(forbidden & set(entitlements) for entitlements in shipped), shipped)


def TestEntitlements_ShippedService_AddsOnlyDyldEnvironment():
    shipped = signing.service_entitlements(GROUP)
    tested = signing.test_entitlements(shipped)
    check("TestEntitlements_ShippedService_AddsOnlyDyldEnvironment",
          tested == {**shipped, "com.apple.security.cs.allow-dyld-environment-variables": True}
          and "com.apple.security.cs.allow-dyld-environment-variables" not in shipped, tested)


def ProductVersion_VersionFile_IsSemanticVersion():
    version = signing.product_version()
    parts = version.split(".")
    check("ProductVersion_VersionFile_IsSemanticVersion",
          len(parts) == 3 and all(part.isdigit() for part in parts), version)


def VersionedInfo_AnyBundle_SetsShortAndBuildVersion():
    info = signing.versioned_info({"CFBundleIdentifier": "com.aex.computeruse", "CFBundleVersion": "195"}, "1.2.3")
    check("VersionedInfo_AnyBundle_SetsShortAndBuildVersion",
          info["CFBundleShortVersionString"] == "1.2.3" and info["CFBundleVersion"] == "1.2.3"
          and info["CFBundleIdentifier"] == "com.aex.computeruse", info)


for test in [SigningOptions_DeveloperIdentity_EnablesRuntimeAndSecureTimestamp,
             SigningOptions_AdHocIdentity_EnablesRuntimeWithoutTimestamp,
             ServiceEntitlements_SignedByTeam_AllowsAppleEventsCalendarsContactsAndGroup,
             ServiceEntitlements_AdHoc_OmitsApplicationGroup,
             ClientEntitlements_SignedByTeam_AllowsAppleEventsAndGroupOnly,
             ShippedEntitlements_AnyRole_NeverAllowInjectionOrUnsignedCode,
             TestEntitlements_ShippedService_AddsOnlyDyldEnvironment,
             ProductVersion_VersionFile_IsSemanticVersion,
             VersionedInfo_AnyBundle_SetsShortAndBuildVersion]:
    test()
print(f"{9 - len(failures)}/9 bundle signing tests passed")
sys.exit(1 if failures else 0)
