"""Run pure shared-number/cache checks and one bounded expected-overflow child."""
from pathlib import Path
import argparse, hashlib, json, resource, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-synthesized-events-result.json')
a = p.parse_args()
sources = [root/'service'/n for n in ['SynthesizedEventNumberSequence.swift', 'SharedSynthesizedEvents.swift', 'EventStreamElementSnapshots.swift']]
sources += [root/'test/synthesized-events.swift']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
frozen = {str(p.relative_to(root)): sha(p) for p in sources}
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
with tempfile.TemporaryDirectory(prefix='cua-synthesized-events-') as directory:
    binary = Path(directory)/'check'
    subprocess.run([a.swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
        *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
        *map(str, sources), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(root/'test/synthesized-events-expected.json'), a.report], check=True, timeout=15)
    overflow = subprocess.run([str(binary), '--overflow'], capture_output=True, text=True, timeout=5)
    assert overflow.returncode in (-4, -5), f'Expected checked signed overflow trap, got {overflow.returncode}'
    assert 'Counter overflow did not trap' not in overflow.stderr
assert frozen == {str(p.relative_to(root)): sha(p) for p in sources}
record = json.loads(Path(a.report).read_text())
record.update(source_hashes=frozen, expected_sha256=sha(root/'test/synthesized-events-expected.json'),
    expected_overflow_subprocess_exit_code=overflow.returncode,
    runtime_scope='Only counter getter sequences with a seeded owned-copy word. Snapshot views, concurrency and failure ordering are owned checks.')
Path(a.report).write_text(json.dumps(record, indent=2)+'\n')
assert record['passed']
print(json.dumps(dict(passed=True, checks=record['cases'], getter_sequence_pairs=record['expectedGetterSequencePairs'],
    expected_overflow_subprocess_exit_code=overflow.returncode, native_UI_input=False)))
