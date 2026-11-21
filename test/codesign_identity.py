"""Code-signing identity for fixtures that run against real TCC grants."""

import os


IDENTITY_VARIABLE = "CODESIGN_IDENTITY"
AD_HOC_IDENTITY = "-"


def physical_signing_identity():
    """Return the identity that holds this Mac's Accessibility and Screen Recording grants.

    TCC ties a grant to the signing identity, so an ad-hoc signature would make
    every rebuild a new, ungranted app. That failure looks like a broken test, so
    a missing identity stops the run here instead.
    """
    identity = os.environ.get(IDENTITY_VARIABLE, "").strip()

    if not identity or identity == AD_HOC_IDENTITY:
        raise SystemExit(f"Set {IDENTITY_VARIABLE} to the code-signing identity that holds this Mac's TCC grants")

    return identity
