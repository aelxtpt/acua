"""Run the hidden Settings accessory fixtures against the selected full graph."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

from codesign_identity import physical_signing_identity

PROJECT = Path(__file__).resolve().parents[1]
FIXTURES = ['settings-accessory-native.swift', 'settings-live-native-current.swift']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
read = lambda p: json.loads(p.read_text())


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def key(manifest):
    return hashlib.sha256(json.dumps(dict(
        native=sha(manifest), package=sha(manifest.parent / 'package-build-result.json'),
        builder=sha(Path(__file__)), fixtures={n: sha(PROJECT / 'test' / n) for n in FIXTURES}), sort_keys=True).encode()).hexdigest()


def valid_receipt(manifest, output):
    try:
        result = read(output.parent / 'build-result.json')
        normal = read(manifest)
        expected = {str((PROJECT / n).resolve()): h for n, h in normal['source_hashes'].items()}
        return (result['key'] == key(manifest) and result['build_terminal']
                and result['build_exit_code'] == 0 and result['signature_verified']
                and result['normal_source_hashes'] == expected
                and result['compiled_Swift_inputs'] == normal['swift_inputs'] + 2
                and result['executable_sha256'] == sha(output)
                and all(sha(Path(n)) == h for field in ['normal_source_hashes',
                    'fixture_source_hashes', 'generated_source_hashes', 'compile_input_hashes']
                    for n, h in result[field].items()))
    except (KeyError, ValueError, TypeError, OSError):
        return False


def build(manifest, output):
    manifest, output = manifest.resolve(strict=True), output.resolve()
    if valid_receipt(manifest, output):
        print('Selected hidden native Settings graph: verified cache hit', flush=True)
        return
    normal = read(manifest)
    expected = {str((PROJECT / n).resolve()): h for n, h in normal['source_hashes'].items()}
    assert all(sha(Path(n)) == h for n, h in expected.items())
    stage = output.parent
    stage.mkdir(parents=True, exist_ok=True)
    command = list(normal['command'])
    production_main = next(Path(n) for n in command if n.endswith('/main.swift'))
    prefix = '''import AppKit
import Foundation
import Darwin

setbuf(stdout, nil)
NSApplication.shared.setActivationPolicy(.prohibited)
do {
    try MainActor.assumeIsolated { try OwnedSettingsAccessoryNativeChecks.run() }
} catch {
    fputs("Owned hidden accessory test failed: \\(error)\\n", stderr)
    exit(1)
}
Task { @MainActor in
    do { try await OwnedLiveSettingsNativeChecks.run(); exit(0) }
    catch { fputs("Owned live tracking test failed: \\(error)\\n", stderr); exit(1) }
}
NSApplication.shared.run()
exit(4)

'''
    generated = stage / 'main.swift'
    generated.write_text(prefix + production_main.read_text())
    command[command.index(str(production_main))] = str(generated)
    for name in FIXTURES:
        command.insert(command.index('-o'), str(PROJECT / 'test' / name))
    command[command.index('-o') + 1] = str(output)
    inputs = {n: sha(Path(n)) for i, n in enumerate(command)
              if i != command.index('-o') + 1 and Path(n).is_file()}
    result = dict(key=key(manifest), native_build_manifest_sha256=sha(manifest),
        package_manifest_sha256=sha(manifest.parent / 'package-build-result.json'),
        normal_source_hashes=expected, fixture_source_hashes={str(PROJECT / 'test' / n):
            sha(PROJECT / 'test' / n) for n in FIXTURES},
        generated_source_hashes={str(generated): sha(generated)}, compile_input_hashes=inputs,
        command=command, fixture_sources_or_assertions_modified=False,
        fixture_modification_scope='The builder preserves its selected fixture sources; the native-current tracker fixture intentionally asserts the replacement/unfiltered contract.',
        legacy_tracker_fixture_preserved_separately=True,
        ordinary_service_main_preserved_after_owned_exit=True,
        native_source_providers_replaced=False,
        source_fixture_drag_session_is_controlled=True,
        physical_input_or_global_clipboard_requested=False)
    write(stage / 'prepared-source-manifest.json', result)
    with (stage / 'build.log').open('w') as log:
        compiled = subprocess.run(command, cwd=PROJECT / 'service', stdout=log,
                                  stderr=subprocess.STDOUT, timeout=600)
    assert all(sha(Path(n)) == h for n, h in inputs.items())
    assert compiled.returncode == 0, 'Selected Settings graph failed to compile; see build.log'
    subprocess.run(['codesign', '--force', '--sign',
        physical_signing_identity(), '--timestamp=none',
        '--identifier', 'test.acua.owned-native-settings', str(output)],
        check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(output)], check=True, capture_output=True)
    result.update(build_terminal=True, build_exit_code=0, signature_verified=True,
        executable_sha256=sha(output), compiled_Swift_inputs=sum(n.endswith('.swift') for n in inputs))
    assert result['compiled_Swift_inputs'] == normal['swift_inputs'] + 2
    write(stage / 'build-result.json', result)
    assert valid_receipt(manifest, output)
    print('Selected hidden native Settings graph compiled and signed', flush=True)


def run(manifest, output, results):
    build(manifest, output)
    assert valid_receipt(manifest, output)
    results.mkdir(parents=True, exist_ok=False)
    with (results.parent / (results.name + '.log')).open('w') as log:
        result = subprocess.run([str(output.resolve()), str(results.resolve())],
                                stdout=log, stderr=subprocess.STDOUT, timeout=30)
    write(results.parent / (results.name + '-execution.json'), dict(
        terminal=True, exit_code=result.returncode, physical_input_executed=False,
        global_clipboard_used=False, native_drag_session_executed=False))
    assert result.returncode == 0, 'Owned hidden native Settings fixture failed; see run log'
    assert read(results / 'result.json')['passed'] and read(results / 'native-result.json')['passed']
    assert valid_receipt(manifest, output)
    print('Selected hidden native Settings fixtures passed', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--results', type=Path)
    args = parser.parse_args()
    if args.results:
        run(args.manifest, args.output, args.results)
    else:
        build(args.manifest, args.output)
