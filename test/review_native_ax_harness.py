"""Build seven owned native read fixtures against the selected package's complete graph."""
from pathlib import Path
import argparse, hashlib, json, subprocess

from codesign_identity import physical_signing_identity

PROJECT = Path(__file__).resolve().parents[1]
GROUPS = [10, 21, 32, 42, 84, 91, 97]
FIXTURES = ['event-stream-children-native.swift', 'event-stream-tree-focus-native.swift',
            'event-stream-invalidation-monitor-native.swift', 'event-stream-native-selection-records-native.swift',
            'event-stream-attributed-native.swift', 'event-stream-snapshots-native.swift',
            'event-stream-context-native.swift']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
read = lambda p: json.loads(p.read_text())
def write(p, value):
    p.write_text(json.dumps(value, indent=2) + '\n')

def build_key(manifest):
    return hashlib.sha256(json.dumps(dict(native=sha(manifest),
        package=sha(manifest.parent / 'package-build-result.json'),
        fixtures={str(PROJECT / 'test' / n): sha(PROJECT / 'test' / n) for n in FIXTURES},
        builder=sha(Path(__file__))), sort_keys=True).encode()).hexdigest()

def prepare(manifest, output):
    manifest = manifest.resolve(strict=True)
    output = output.resolve()
    S, P = output.parent, PROJECT
    S.mkdir(parents=True, exist_ok=True)
    normal_file = manifest
    package_file = manifest.parent / 'package-build-result.json'
    normal = read(normal_file)
    assert all(sha(P / n) == h for n, h in normal['source_hashes'].items())
    fixtures = {
        10: ('event-stream-children-native.swift', 'EventStreamChildrenNativeTests', False),
        21: ('event-stream-tree-focus-native.swift', 'EventStreamTreeFocusNativeTests', True),
        32: ('event-stream-invalidation-monitor-native.swift', 'InvalidationMonitorNativeTests', True),
        42: ('event-stream-native-selection-records-native.swift', 'NativeSelectionRecordTests', True),
        84: ('event-stream-attributed-native.swift', 'AttributedNativeTests', False),
        91: ('event-stream-snapshots-native.swift', 'EventStreamNativeSnapshotTests', False),
        97: ('event-stream-context-native.swift', 'EventStreamNativeContextTests', False),
    }
    command = list(normal['command'])
    production_main = next(Path(n) for n in command if n.endswith('/main.swift'))
    production = production_main.read_text()
    synchronous = '\n'.join('    case "' + str(group) + '": try MainActor.assumeIsolated { try '
                            + name + '.main() }; exit(0)'
                            for group, (_, name, asynchronous) in fixtures.items() if not asynchronous)
    asynchronous = '\n'.join('            case "' + str(group) + '": try await ' + name + '.main()'
                             for group, (_, name, asynchronous) in fixtures.items() if asynchronous)
    fixture_cases = '\n'.join('        case "' + str(group) + '": ' + name + '.fixture()'
                             for group, (_, name, asynchronous) in fixtures.items() if asynchronous)
    prefix = '''import AppKit
import Foundation
import Darwin

// Owned fixture selection is inherited by fixture children without changing
// their argument counts or running ordinary service startup.
guard let ownedReadGroup = ProcessInfo.processInfo.environment["CUA_NATIVE_READ_GROUP"],
      ["10", "21", "32", "42", "84", "91", "97"].contains(ownedReadGroup) else {
    FileHandle.standardError.write(Data("An owned native read group is required.\\n".utf8))
    exit(2)
}
// AppKit fixtures must enter app.run() from the top-level thread. Holding a
// MainActor task across app.run() prevents their main-queue readiness work.
if CommandLine.arguments.dropFirst().first == "--fixture",
   ["21", "32", "42"].contains(ownedReadGroup) {
    MainActor.assumeIsolated {
        switch ownedReadGroup {
''' + fixture_cases + '''
        default: preconditionFailure("Unexpected asynchronous fixture")
        }
        exit(0)
    }
}
do {
    switch ownedReadGroup {
''' + synchronous + '''
    default:
        Task { @MainActor in
            do {
                switch ownedReadGroup {
''' + asynchronous + '''
                default: exit(2)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("Owned native read fixture failed: \\(error)\\n").utf8))
                exit(1)
            }
        }
    }
} catch {
    FileHandle.standardError.write(Data(("Owned native read fixture failed: \\(error)\\n").utf8))
    exit(1)
}
RunLoop.main.run()
exit(4)

'''
    main = S / 'main.swift'
    main.write_text(prefix + production)
    command[command.index(str(production_main))] = str(main)
    generated = [main]
    fixture_hashes = {}
    transformations = {}
    for group, (filename, _, _) in fixtures.items():
        path = P / 'test' / filename
        source = path.read_text()
        assert source.count('@main') == 1 and 'child.environment' not in source
        fixture_hashes[str(path)] = sha(path)
        transformed = source.replace('@main', '', 1)
        changes = ['remove standalone @main attribute; preserve all argument counts and session guards']
        if group in [10, 97]:
            name = 'ChildrenReadOnlyPanel' if group == 10 else 'ContextReadOnlyPanel'
            panel = '\n@MainActor private final class ' + name + ''': NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
'''
            assert transformed.count('import ApplicationServices\n') == 1
            transformed = transformed.replace('import ApplicationServices\n', 'import ApplicationServices\n' + panel, 1)
            assert transformed.count('NSWindow(contentRect:') == 1 and transformed.count('styleMask:[.titled]') == 1
            transformed = transformed.replace('NSWindow(contentRect:', name + '(contentRect:', 1)
            transformed = transformed.replace('styleMask:[.titled]', 'styleMask:[.titled,.nonactivatingPanel]', 1)
            anchor = 'window.orderBack(nil);app.finishLaunching()'
            assert transformed.count(anchor) == 1
            transformed = transformed.replace(anchor, anchor + '\n        precondition(!window.canBecomeKey && !window.canBecomeMain && !window.isKeyWindow)', 1)
            changes.append('use an owned nonactivating NSPanel and enforce non-key/non-main state')
        old_checks = [l.strip() for l in source.splitlines() if l.strip().startswith('check(')]
        new_checks = [l.strip() for l in transformed.splitlines() if l.strip().startswith('check(')]
        assert old_checks == new_checks
        assert 'CGSSessionScreenIsLocked' in transformed and 'AXIsProcessTrusted' in transformed
        target = S / filename
        target.write_text(transformed)
        generated.append(target)
        transformations[str(group)] = changes
        command.insert(command.index('-o'), str(target))
    command[command.index('-o') + 1] = str(output)
    compile_inputs = {n: sha(Path(n)) for index, n in enumerate(command)
        if index != command.index('-o') + 1 and Path(n).is_file()}
    write(S / 'build-command.json', command)
    prepared = dict(package_manifest_sha256=sha(package_file),
        native_build_manifest_sha256=sha(normal_file), groups=list(fixtures),
        normal_source_hashes={str((P / n).resolve()): h for n, h in normal['source_hashes'].items()},
        fixture_source_hashes=fixture_hashes, generated_source_hashes={str(p): sha(p) for p in generated},
        compile_input_hashes=compile_inputs, transformations=transformations,
        all_fixture_assertions_and_unlocked_session_guards_preserved=True,
        ordinary_service_main_preserved_after_owned_exit=True,
        native_request_or_effect_providers_replaced=False,
        physical_input_or_capture_requested=False, runtime_executed=False)
    prepared['key'] = build_key(normal_file)
    write(S / 'prepared-source-manifest.json', prepared)
    return command, prepared

def build(manifest, output):
    manifest = manifest.resolve(strict=True)
    output = output.resolve()
    stage = output.parent
    normal = read(manifest)
    inputs = {str((PROJECT / n).resolve()): h for n, h in normal['source_hashes'].items()}
    assert all(sha(Path(n)) == h for n, h in inputs.items())
    receipt = stage / 'build-result.json'
    if receipt.exists() and output.exists():
        cached = read(receipt)
        if (cached.get('key') == build_key(manifest) and cached.get('groups') == GROUPS
                and cached.get('normal_source_hashes') == inputs
                and cached.get('build_terminal') and cached.get('build_exit_code') == 0
                and cached.get('executable_sha256') == sha(output)
                and all(sha(Path(n)) == h for field in ['fixture_source_hashes',
                    'generated_source_hashes', 'compile_input_hashes'] for n, h in cached[field].items())):
            print('Selected seven-group native AX graph: verified cache hit', flush=True)
            return
    command, prepared = prepare(manifest, output)
    with (stage / 'build.log').open('w') as log:
        result = subprocess.run(command, cwd=PROJECT / 'service', stdout=log,
                                stderr=subprocess.STDOUT, timeout=600)
    assert all(sha(Path(n)) == h for n, h in inputs.items())
    assert all(sha(Path(n)) == h for n, h in prepared['fixture_source_hashes'].items())
    assert result.returncode == 0, 'Selected native read fixtures failed to compile; see build.log'
    signature = subprocess.run(['codesign', '--force', '--sign',
        physical_signing_identity(), '--timestamp=none',
        '--identifier', 'test.acua.owned-native-ax', str(output)], capture_output=True, check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(output)], check=True, capture_output=True)
    prepared.update(build_terminal=True, build_exit_code=0, signature_verified=True,
        signature_exit_code=signature.returncode, executable_sha256=sha(output),
        compiled_Swift_inputs=sum(n.endswith('.swift') for n in prepared['compile_input_hashes']))
    assert prepared['compiled_Swift_inputs'] == normal['swift_inputs'] + len(GROUPS)
    write(receipt, prepared)
    print('Selected seven-group native read graph compiled and signed', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare-only', action='store_true', help='generate and verify compilation inputs without compiling or launching')
    options = parser.parse_args()
    if options.prepare_only:
        prepare(options.manifest, options.output)
    else:
        build(options.manifest, options.output)
