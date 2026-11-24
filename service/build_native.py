"""Build the selected native service and its support applications from source."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile

import bundle_signing


SERVICE = Path(__file__).resolve().parent
PROJECT = SERVICE.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def run(command, log):
    with log.open("w") as output:
        result = subprocess.run(command, cwd=SERVICE, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        sys.stderr.write(log.read_text()[-10000:])
        raise subprocess.CalledProcessError(result.returncode, command)


def source_hashes(paths):
    return {str(path.relative_to(PROJECT)) if path.is_relative_to(PROJECT) else str(path): sha(path) for path in paths}


def verify_sources(hashes):
    if any(sha(PROJECT / name) != digest for name, digest in hashes.items()):
        raise RuntimeError("Sources changed during compilation. Run the build again.")


class NativeBuild:
    def __init__(self, arguments):
        self.args = arguments
        self.selection = read(SERVICE / "native-sources.json")
        self.swiftc = shlex.split(arguments.swiftc)
        self.clang = shlex.split(arguments.clang)
        self.flags = shlex.split(arguments.swiftflags)
        self.directory = arguments.build_dir.resolve() / arguments.target
        self.directory.mkdir(parents=True, exist_ok=True)
        self.common = ["-target", arguments.target, "-module-cache-path", arguments.module_cache]
        self.tools = {
            "swift": subprocess.check_output([*self.swiftc, "--version"], text=True).strip(),
            "clang": subprocess.check_output([*self.clang, "--version"], text=True).strip(),
            "sdk": subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
            "sdk_version": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
        }
        self.identity = dict(target=arguments.target, tools=self.tools, project=str(PROJECT), builder=sha(Path(__file__)))
        inputs = [PROJECT / name for name in self.selection["service_sources"] + self.selection["client_sources"]]
        inputs.extend(PROJECT / name for name in self.selection["service_bridges"])
        inputs.extend([PROJECT / self.selection["client_bridge"], PROJECT / self.selection["client_header"],
                       SERVICE / "native-sources.json", Path(__file__), SERVICE / "CalendarPermissionInfo.plist",
                       SERVICE / "ClientInfo.plist", SERVICE / "GuardianInfo.plist"])
        inputs.extend(PROJECT / name for name in self.selection["client_resources"].values())
        inputs.append(SERVICE / "build_mcp.py")
        self.mcp_patches = runpy.run_path(str(SERVICE / "mcp_patches.py"))
        inputs.extend(self.mcp_patches["input_files"]())
        self.inputs = source_hashes(inputs)

    def vendor(self, key):
        directory = PROJECT / self.selection[key]
        upstream = read(directory / "UPSTREAM.json")
        for name, digest in upstream["files"].items():
            if sha(directory / name) != digest:
                raise RuntimeError(f"Pinned dependency source changed: {directory / name}")
        return directory, sha(directory / "UPSTREAM.json")

    def module_directory(self, name, upstream, outputs):
        identity = dict(self.identity, upstream=upstream)
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:20]
        directory = self.directory / "sdk" / name / key
        directory.mkdir(parents=True, exist_ok=True)
        manifest = directory / "build-result.json"
        previous = read(manifest) if manifest.exists() else {}
        valid = (previous.get("identity") == identity and set(previous.get("outputs", {})) == set(outputs) and
                 all((directory / path).is_file() and sha(directory / path) == digest
                     for path, digest in previous.get("outputs", {}).items()))
        return directory, identity, valid

    def build_toml(self):
        vendor, upstream = self.vendor("toml_vendor")
        outputs = ["ctoml.o", "module.modulemap", "CUAToml.swiftmodule", "libCUAToml.a"]
        directory, identity, valid = self.module_directory("toml", upstream, outputs)
        if not valid:
            print("Building TOML dependency", flush=True)
            header = vendor / "Sources/CTomlPlusPlus/include/ctoml.h"
            (directory / "module.modulemap").write_text(
                "module CTomlPlusPlus { header " + json.dumps(str(header), ensure_ascii=False) + " export * }\n")
            run([*self.clang, "-std=c++17", "-O2", "-target", self.args.target, "-fvisibility=hidden",
                 "-I", str(header.parent), "-c", str(vendor / "Sources/CTomlPlusPlus/ctoml.cpp"),
                 "-o", str(directory / "ctoml.o")], directory / "cpp.log")
            sources = sorted((vendor / "Sources/TOML").glob("*.swift"))
            run([*self.swiftc, "-swift-version", "6", "-O", *self.common, "-parse-as-library", "-module-name", "CUAToml",
                 "-I", str(directory), "-emit-library", "-static", "-emit-module", "-emit-module-path",
                 str(directory / "CUAToml.swiftmodule"), *map(str, sources), str(directory / "ctoml.o"),
                 "-o", str(directory / "libCUAToml.a")], directory / "swift.log")
            self.vendor("toml_vendor")
            write(directory / "build-result.json", dict(identity=identity, outputs={name: sha(directory / name) for name in outputs}))
        return directory

    def build_argument_parser(self):
        vendor, upstream = self.vendor("argument_parser_vendor")
        modules = ["ArgumentParserToolInfo", "ArgumentParser"]
        outputs = [path for name in modules for path in (name + ".swiftmodule", "lib" + name + ".a")]
        directory, identity, valid = self.module_directory("argument-parser", upstream, outputs)
        if not valid:
            print("Building argument parser dependency", flush=True)
            for module in modules:
                sources = sorted((vendor / "Sources" / module).rglob("*.swift"))
                run([*self.swiftc, "-swift-version", "5", "-O", "-whole-module-optimization", *self.common,
                     "-parse-as-library", "-module-name", module, "-emit-module", "-emit-module-path",
                     str(directory / (module + ".swiftmodule")), "-emit-library", "-static", "-I", str(directory),
                     *map(str, sources), "-o", str(directory / ("lib" + module + ".a"))], directory / (module + ".log"))
            self.vendor("argument_parser_vendor")
            write(directory / "build-result.json", dict(identity=identity, outputs={name: sha(directory / name) for name in outputs}))
        return directory

    def build_bridge(self, source, includes=()):
        path = PROJECT / source
        hashes = source_hashes([path, *includes])
        identity = dict(self.identity, sources=hashes, includes=list(map(str, includes)))
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:20]
        directory = self.directory / "bridges" / key
        directory.mkdir(parents=True, exist_ok=True)
        output = directory / (path.stem + ".o")
        metadata = directory / "build-result.json"
        previous = read(metadata) if metadata.exists() else {}
        if previous.get("identity") == identity and output.exists() and previous.get("sha256") == sha(output):
            return output
        flags = [value for header in includes for value in ("-I", str(header.parent))]
        run([*self.clang, "-target", self.args.target, "-fobjc-arc", "-fobjc-exceptions", "-fblocks", "-O2",
             "-Wall", "-Wextra", "-Werror", *flags, "-c", str(path), "-o", str(output)], directory / "build.log")
        verify_sources(hashes)
        write(metadata, dict(identity=identity, sha256=sha(output)))
        return output

    def build_mcp(self):
        names = ["Logging", "SystemPackage", "MCP"]
        outputs = [item for name in names for item in (name + ".swiftmodule", "lib" + name + ".a")]
        provenance = {}
        for key in ["mcp_vendor", "logging_vendor", "system_vendor"]:
            _, provenance[key] = self.vendor(key)
        provenance["builder"] = sha(SERVICE / "build_mcp.py")
        provenance["local_patches"] = self.mcp_patches["identity"]()
        directory, identity, valid = self.module_directory("mcp", provenance, outputs)
        metadata = directory / "build-result.json"
        if not valid:
            run([sys.executable, str(SERVICE / "build_mcp.py"), "--swiftc", self.args.swiftc,
                 "--target", self.args.target, "--module-cache", self.args.module_cache,
                 "--output", str(directory)], directory / "build.log")
            built = read(metadata)
            assert set(built["outputs"]) == set(outputs)
            write(directory / "sdk-build-result.json", built)
            write(metadata, dict(identity=identity, outputs={name: sha(directory / name) for name in outputs}))
        return directory

    def compile(self, role, executable, sources, flags, objects, info, extra_inputs=(), entitlements=None):
        paths = [*sources, *objects, info, *extra_inputs, *([entitlements] if entitlements else [])]
        hashes = source_hashes([path for path in paths if path.is_relative_to(PROJECT)])
        external = {str(path): sha(path) for path in paths if not path.is_relative_to(PROJECT)}
        identity = dict(self.identity, flags=flags, sources=hashes, external=external, signing_identity=self.args.identity)
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:20]
        directory = self.directory / "bin" / role / key
        directory.mkdir(parents=True, exist_ok=True)
        binary = directory / executable
        metadata = directory / "build-result.json"
        previous = read(metadata) if metadata.exists() else {}
        if previous.get("identity") == identity and binary.exists() and previous.get("binary_sha256") == sha(binary):
            return binary, previous
        print("Building " + executable, flush=True)
        temporary = directory / (executable + ".building")
        command = [*self.swiftc, *flags, *self.common, "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                   "-Xlinker", "__info_plist", "-Xlinker", str(info), *map(str, sources), *map(str, objects),
                   "-o", str(temporary)]
        run(command, directory / "compiler.log")
        run([*shlex.split(self.args.codesign), "--force", "--sign", self.args.identity, "--timestamp=none",
             "--identifier", "com.aex.computeruse" + ("." + role if role != "service" else ""),
             *(["--entitlements", str(entitlements)] if entitlements else []),
             str(temporary)], directory / "signing.log")
        verify_sources(hashes)
        if any(sha(Path(name)) != digest for name, digest in external.items()):
            raise RuntimeError("A dependency changed during compilation")
        os.replace(temporary, binary)
        record = dict(exit_code=0, command=command, binary=str(binary), binary_sha256=sha(binary), identity=identity)
        write(metadata, record)
        return binary, record

    def service(self):
        toml = self.build_toml()
        sources = [PROJECT / name for name in self.selection["service_sources"]]
        bridges = [self.build_bridge(name) for name in self.selection["service_bridges"]]
        objects = [*bridges, toml / "libCUAToml.a"]
        flags = [*self.flags, "-module-name", "AexComputerUseService",
                 "-I", str(toml), "-lc++"]
        for name in self.selection["service_features"]:
            flags.extend(["-enable-upcoming-feature", name])
        for name in self.selection["service_defines"]:
            flags.extend(["-D", name])
        binary, record = self.compile("service", "AexComputerUseService", sources, flags, objects,
                                      SERVICE / "CalendarPermissionInfo.plist",
                                      [toml / "CUAToml.swiftmodule"])
        configuration = [toml / "build-result.json",
                         toml / "CUAToml.swiftmodule", toml / "module.modulemap", SERVICE / "CalendarPermissionInfo.plist"]
        inputs = source_hashes([*sources, *bridges, toml / "libCUAToml.a"])
        record.update(source_hashes=inputs, configuration_hashes={str(path): sha(path) for path in configuration},
                      inputs=len(inputs), swift_inputs=len(sources), installed=False,
                      source_selection_sha256=sha(SERVICE / "native-sources.json"))
        verify_sources(self.inputs)
        write(self.args.build_dir / "native-build-result.json", record)
        output = self.args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".building")
        shutil.copy2(binary, temporary)
        os.replace(temporary, output)
        return binary, sources, flags, objects

    def signing_team(self, service_binary):
        # macOS team-prefixed groups use the actual signing team's namespace.
        # Ad-hoc builds retain the unavailable-container behavior.
        command = shlex.split(self.args.codesign)
        subprocess.run([*command, "--verify", "--strict", str(service_binary)], check=True, capture_output=True)
        signature = subprocess.run([*command, "--display", "--verbose=4", str(service_binary)],
                                   check=True, capture_output=True, text=True)
        match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature.stderr, re.MULTILINE)
        team = match.group(1) if match else None
        if not team and self.args.identity != "-":
            raise RuntimeError("The signed service has no developer team for its application group")
        return team

    def service_configuration(self, service_binary):
        team = self.signing_team(service_binary)
        group = team + ".com.aex.computeruse" if team else None
        info = plistlib.loads((SERVICE / "CalendarPermissionInfo.plist").read_bytes())
        # Explicitly disable the shared-container route in ad-hoc bundles.
        # Raw executables carry no Info.plist and have no group storage.
        info["CUAApplicationGroupIdentifier"] = group or ""
        entitlements = bundle_signing.service_entitlements(group)
        configuration = dict(signing_team=team, application_group=group, info=info, entitlements=entitlements)
        key = hashlib.sha256(json.dumps(configuration, sort_keys=True).encode()).hexdigest()[:20]
        directory = self.directory / "configuration/service" / key
        directory.mkdir(parents=True, exist_ok=True)
        info_path = directory / "ServiceInfo.plist"
        info_path.write_bytes(plistlib.dumps(info))
        entitlement_path = directory / "Service.entitlements.plist" if entitlements else None
        if entitlement_path:
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
        record = dict(signing_team=team, application_group=group, info_sha256=sha(info_path),
                      entitlements_sha256=sha(entitlement_path) if entitlement_path else None)
        write(directory / "configuration.json", record)
        return info_path, entitlement_path, record

    def client_configuration(self, service_binary):
        team = self.signing_team(service_binary)
        info = plistlib.loads((SERVICE / "ClientInfo.plist").read_bytes())
        info.pop("CUAApplicationGroupIdentifier", None)
        group = team + ".com.aex.computeruse" if team else None
        if group:
            info["CUAApplicationGroupIdentifier"] = group
        entitlements = bundle_signing.client_entitlements(group)
        configuration = dict(signing_team=team, application_group=group, info=info, entitlements=entitlements)
        key = hashlib.sha256(json.dumps(configuration, sort_keys=True).encode()).hexdigest()[:20]
        directory = self.directory / "configuration/client" / key
        directory.mkdir(parents=True, exist_ok=True)
        info_path = directory / "ClientInfo.plist"
        info_path.write_bytes(plistlib.dumps(info))
        entitlement_path = directory / "Client.entitlements.plist" if entitlements else None
        if entitlement_path:
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
        record = dict(signing_team=team, application_group=group, info_sha256=sha(info_path),
                      entitlements_sha256=sha(entitlement_path) if entitlement_path else None)
        write(directory / "configuration.json", record)
        return info_path, entitlement_path, record

    def bundle(self, binary, sources, service_flags, service_objects):
        service_info, service_entitlements, service_configuration = self.service_configuration(binary)
        client_info, client_entitlements, client_configuration = self.client_configuration(binary)
        parser = self.build_argument_parser()
        mcp = self.build_mcp()
        header = PROJECT / self.selection["client_header"]
        bridge = self.build_bridge(self.selection["client_bridge"], [header])
        client_sources = [PROJECT / name for name in self.selection["client_sources"]]
        client, _ = self.compile(
            "client", "AexComputerUseClient", client_sources,
            ["-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-O",
             "-whole-module-optimization", "-module-name", "ComputerUseClient", "-parse-as-library",
             "-import-objc-header", str(header), "-I", str(parser), "-I", str(mcp),
             "-I", str(PROJECT / self.selection["system_vendor"] / "Sources/CSystem/include"),
             "-lbsm"],
            [bridge, parser / "libArgumentParser.a", parser / "libArgumentParserToolInfo.a",
             mcp / "libMCP.a", mcp / "libLogging.a", mcp / "libSystemPackage.a"], client_info,
            [header, parser / "ArgumentParser.swiftmodule", parser / "ArgumentParserToolInfo.swiftmodule",
             *[mcp / (name + ".swiftmodule") for name in ["Logging", "SystemPackage", "MCP"]]],
            entitlements=client_entitlements)
        guardian_flags = list(service_flags)
        guardian_flags[guardian_flags.index("-module-name") + 1] = "CUALockScreenGuardian"
        toml = self.build_toml()
        guardian, _ = self.compile("guardian", "AexLockScreenGuardian", sources, guardian_flags, service_objects,
                                   SERVICE / "GuardianInfo.plist",
                                   [toml / "CUAToml.swiftmodule"])
        verify_sources(self.inputs)
        toml_vendor = PROJECT / self.selection["toml_vendor"]
        argument_vendor = PROJECT / self.selection["argument_parser_vendor"]
        licenses = {
            "swift-toml-LICENSE.md": toml_vendor / "LICENSE.md",
            "tomlplusplus-header-with-license.hpp": toml_vendor / "Sources/CTomlPlusPlus/toml.hpp",
            "swift-argument-parser-LICENSE.txt": argument_vendor / "LICENSE.txt",
            "swift-mcp-LICENSE": PROJECT / self.selection["mcp_vendor"] / "LICENSE",
            "swift-log-LICENSE.txt": PROJECT / self.selection["logging_vendor"] / "LICENSE.txt",
            "swift-log-NOTICE.txt": PROJECT / self.selection["logging_vendor"] / "NOTICE.txt",
            "swift-system-LICENSE.txt": PROJECT / self.selection["system_vendor"] / "LICENSE.txt",
        }
        destination = self.args.bundle.resolve()
        with tempfile.TemporaryDirectory(prefix="bundle-", dir=self.args.build_dir) as temporary:
            app = Path(temporary) / destination.name
            roles = [(app, binary, service_info, service_entitlements),
                     (app / "Contents/SharedSupport/AexComputerUseClient.app", client, client_info, client_entitlements),
                     (app / "Contents/SharedSupport/AexLockScreenGuardian.app", guardian, SERVICE / "GuardianInfo.plist", None)]
            minimum = self.args.target.split("macosx", 1)[1]
            version = bundle_signing.product_version()
            for bundle, payload, info_path, entitlements in reversed(roles):
                macos = bundle / "Contents/MacOS"
                macos.mkdir(parents=True, exist_ok=True)
                shutil.copy2(payload, macos / payload.name)
                info = bundle_signing.versioned_info(plistlib.loads(info_path.read_bytes()), version)
                info.update(CFBundleExecutable=payload.name, CFBundlePackageType="APPL",
                            LSUIElement=True, LSMinimumSystemVersion=minimum)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                if bundle == app or payload == guardian:
                    shutil.copytree(SERVICE / "Resources", bundle / "Contents/Resources")
                notices = bundle / "Contents/Resources/Licenses"
                notices.mkdir(parents=True, exist_ok=True)
                if payload == client:
                    resources = bundle / "Contents/Resources"
                    resources.mkdir(exist_ok=True)
                    for name, source in self.selection["client_resources"].items():
                        shutil.copy2(PROJECT / source, resources / name)
                names = ["swift-argument-parser-LICENSE.txt", "swift-mcp-LICENSE",
                         "swift-log-LICENSE.txt", "swift-log-NOTICE.txt", "swift-system-LICENSE.txt"] if payload == client else [
                    "swift-toml-LICENSE.md", "tomlplusplus-header-with-license.hpp"]
                for name in names:
                    shutil.copy2(licenses[name], notices / name)
                run([*shlex.split(self.args.codesign), "--force", "--sign", self.args.identity,
                     *bundle_signing.signing_options(self.args.identity),
                     *(["--entitlements", str(entitlements)] if entitlements else []),
                     str(bundle)], Path(temporary) / (payload.name + "-signing.log"))
            run([*shlex.split(self.args.codesign), "--verify", "--deep", "--strict", str(app)],
                Path(temporary) / "verification.log")
            destination.parent.mkdir(parents=True, exist_ok=True)
            backup = destination.with_name(destination.name + ".previous")
            if backup.exists():
                raise RuntimeError(f"A previous bundle publication is unfinished: {backup}")
            if destination.exists():
                os.replace(destination, backup)
            try:
                os.replace(app, destination)
            except BaseException:
                if backup.exists():
                    os.replace(backup, destination)
                raise
            if backup.exists():
                shutil.rmtree(backup)
        with tempfile.TemporaryDirectory(prefix="package-", dir=self.args.build_dir) as temporary:
            package = Path(temporary) / "release"
            distribution = package / "dist"
            distribution.mkdir(parents=True)
            target_app = distribution / destination.name
            shutil.copytree(destination, target_app)
            shutil.copytree(PROJECT / "rust/cua-client", distribution / "rust/cua-client",
                            ignore=shutil.ignore_patterns("target"))
            (distribution / "Licenses").mkdir()
            for name, source in licenses.items():
                shutil.copy2(source, distribution / "Licenses" / name)
            (distribution / "README.md").write_text(
                "Built from the project's selected native sources. The embeddable Rust library is in rust/cua-client.\n")
            files = {str(path.relative_to(distribution)): sha(path) for path in distribution.rglob("*") if path.is_file()}
            shutil.copy2(self.args.build_dir / "native-build-result.json", package / "native-build-result.json")
            write(package / "package-build-result.json", dict(
                app_bundle=destination.name, files=files,
                service_binary_sha256=sha(target_app / "Contents/MacOS/AexComputerUseService"),
                build_manifest_sha256=sha(package / "native-build-result.json"),
                service_configuration=service_configuration,
                client_configuration=client_configuration,
                Rust_library_version=re.search(r'^version\s*=\s*"([^"]+)"',
                    (distribution / "rust/cua-client/Cargo.toml").read_text(), re.MULTILINE).group(1), installed=False))
            key = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()[:20]
            release = self.args.build_dir / "packages" / key
            release.parent.mkdir(exist_ok=True)
            if not release.exists():
                os.replace(package, release)
            link = self.args.build_dir / ".dist-next"
            if link.is_symlink():
                link.unlink()
            link.symlink_to(release / "dist", target_is_directory=True)
            os.replace(link, self.args.build_dir / "dist")
        print("Built bundle " + str(destination), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--swiftflags", default="-O")
    parser.add_argument("--target", required=True)
    parser.add_argument("--module-cache", required=True)
    parser.add_argument("--build-dir", type=Path, default=SERVICE / ".build/current")
    parser.add_argument("--output", type=Path, default=SERVICE / "AexComputerUseService")
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--codesign", default="codesign")
    parser.add_argument("--identity", default="-")
    parser.add_argument("--print-toml-module", action="store_true",
                        help="build only the TOML module and print its directory (used by unit tests)")
    parser.add_argument("--print-mcp-module", action="store_true",
                        help="build only the MCP SDK modules and print their directory (used by unit tests)")
    args = parser.parse_args()
    if not re.fullmatch(r"(arm64|x86_64)-apple-macosx\d+(?:\.\d+){0,2}", args.target):
        parser.error("provide an arm64 or x86_64 macOS target")
    args.build_dir = args.build_dir.resolve()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    with (args.build_dir / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        builder = NativeBuild(args)
        if args.print_toml_module:
            print(builder.build_toml(), flush=True)
            return
        if args.print_mcp_module:
            print(builder.build_mcp(), flush=True)
            return
        result = builder.service()
        if args.bundle:
            builder.bundle(*result)
    print("Native service build complete", flush=True)


if __name__ == "__main__":
    main()
