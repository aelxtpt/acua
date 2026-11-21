"""Materialize verified local MCP additions without editing pinned upstream files."""
import hashlib
import json
import os
from pathlib import Path
import tempfile

SERVICE = Path(__file__).resolve().parent
ROOT = SERVICE / "mcp-patches"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def input_files():
    manifest = ROOT / "manifest.json"
    value = json.loads(manifest.read_text())
    paths = [Path(__file__), manifest]
    for name in value["patches"]:
        path = (ROOT / name).resolve()
        if not path.is_relative_to(ROOT.resolve()):
            raise ValueError("MCP patch path escapes its directory")
        paths.append(path)
    return paths

def identity():
    return {str(path.relative_to(SERVICE)): sha(path) for path in input_files()}

def apply(vendor, output):
    """Return upstream-path -> generated-path replacements after exact hash checks."""
    vendor = Path(vendor).resolve()
    output = Path(output).resolve()
    if output == vendor or output.is_relative_to(vendor):
        raise ValueError("MCP generated sources must be outside pinned upstream")
    initial = identity()
    manifest = json.loads((ROOT / "manifest.json").read_text())
    if sha(vendor / "UPSTREAM.json") != manifest["upstream_manifest_sha256"]:
        raise ValueError("MCP patch upstream provenance mismatch")
    replacements = {}
    for patch in input_files()[2:]:
        rule = json.loads(patch.read_text())
        relative = Path(rule["source"])
        upstream = (vendor / relative).resolve()
        generated = (output / relative).resolve()
        if not upstream.is_relative_to(vendor) or not generated.is_relative_to(output):
            raise ValueError("MCP patch source path escapes its directory")
        if upstream in replacements:
            raise ValueError("Duplicate MCP patch target")
        if sha(upstream) != rule["before_sha256"]:
            raise ValueError("MCP patch upstream source hash mismatch")
        text = upstream.read_text()
        for change in rule["replacements"]:
            if not change["before"] or text.count(change["before"]) != change["count"]:
                raise ValueError("MCP patch context/count mismatch")
            text = text.replace(change["before"], change["after"])
        data = text.encode()
        if hashlib.sha256(data).hexdigest() != rule["after_sha256"]:
            raise ValueError("MCP patch result hash mismatch")
        generated.parent.mkdir(parents=True, exist_ok=True)
        if not generated.is_file() or generated.read_bytes() != data:
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=generated.parent, prefix=".mcp-patch-", delete=False) as file:
                    temporary = Path(file.name)
                    file.write(data)
                os.replace(temporary, generated)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        replacements[upstream] = generated
    if identity() != initial:
        raise RuntimeError("MCP patches changed while being applied")
    return replacements
