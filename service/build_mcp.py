"""Build the pinned MCP stdio runtime and its direct dependencies offline."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import mcp_patches

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--swiftc", default="swiftc")
parser.add_argument("--target", required=True)
parser.add_argument("--module-cache", required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
service = Path(__file__).resolve().parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
vendors = {name: service / "vendor" / (name + "-" + version)
           for name, version in [("MCP", "0.11.0"), ("Logging", "1.6.4"), ("System", "1.4.2")]}
for path in vendors.values():
    provenance = json.loads((path / "UPSTREAM.json").read_text())
    assert all(sha(path / name) == digest for name, digest in provenance["files"].items())
patch_identity = mcp_patches.identity()
compiler = shlex.split(args.swiftc)
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
modules = [
    ("Logging", sorted((vendors["Logging"] / "Sources/Logging").glob("*.swift")), ["-swift-version", "5"]),
    ("SystemPackage", sorted((vendors["System"] / "Sources/System").rglob("*.swift")),
        ["-swift-version", "5", "-D", "SYSTEM_PACKAGE", "-D", "SYSTEM_PACKAGE_DARWIN", "-I", str(vendors["System"] / "Sources/CSystem/include")]),
    ("MCP", sorted(p for p in (vendors["MCP"] / "Sources/MCP").rglob("*.swift")
        if p.name not in ["HTTPClientTransport.swift", "NetworkTransport.swift"]),
        ["-swift-version", "6", "-strict-concurrency=complete", "-package-name", "MCP", "-I", str(vendors["System"] / "Sources/CSystem/include")]),
]
outputs = [name + suffix for name, _, _ in modules for suffix in [".swiftmodule"]]
with (output / "build.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    patched_sources = mcp_patches.apply(vendors["MCP"], output / "patched-sources")
    modules = [(name, [patched_sources.get(path.resolve(), path) for path in sources], flags)
               for name, sources, flags in modules]
    outputs += ["lib" + name + ".a" for name, _, _ in modules]
    identity = dict(compiler=subprocess.check_output([*compiler, "--version"], text=True).strip(),
        compiler_command=compiler, target=args.target,
        sdk_path=subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
        sdk_version=subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
        builder_sha256=sha(Path(__file__)),
        upstream={name: sha(path / "UPSTREAM.json") for name, path in vendors.items()},
        local_patches=patch_identity,
        module_sources={name: {str(p.relative_to(service)) if p.is_relative_to(service) else str(p): sha(p)
                              for p in sources} for name, sources, _ in modules})
    manifest = output / "build-result.json"
    previous = json.loads(manifest.read_text()) if manifest.exists() else {}
    if previous.get("identity") == identity and set(previous.get("outputs", {})) == set(outputs) and all(
            (output / name).is_file() and sha(output / name) == digest for name, digest in previous["outputs"].items()):
        print("MCP0.11.0: verified stdio runtime cache hit")
    else:
        records = []
        for name, sources, flags in modules:
            command = [*compiler, "-O", "-whole-module-optimization", "-parse-as-library", "-emit-library", "-static", "-emit-module",
                "-target", args.target, "-module-cache-path", args.module_cache, "-I", str(output), *flags,
                "-module-name", name, "-emit-module-path", str(output / (name + ".swiftmodule")),
                *map(str, sources), "-o", str(output / ("lib" + name + ".a"))]
            with (output / (name + ".log")).open("w") as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            records.append(dict(module=name, command=command, exit_code=result.returncode, sources=len(sources)))
            if result.returncode:
                raise SystemExit((output / (name + ".log")).read_text()[-10000:])
        assert mcp_patches.identity() == patch_identity
        for path in vendors.values():
            provenance = json.loads((path / "UPSTREAM.json").read_text())
            assert all(sha(path / name) == digest for name, digest in provenance["files"].items())
        temporary = manifest.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(dict(identity=identity, commands=records,
            outputs={name: sha(output / name) for name in outputs},
            scope="stdio and shared protocol/client/server; HTTP client and Apple Network transports unselected"), indent=2) + "\n")
        temporary.replace(manifest)
        print("MCP0.11.0: built verified stdio runtime and direct dependencies")
