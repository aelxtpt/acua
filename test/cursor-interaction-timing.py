"""Production readiness predicate versus expected decisions, plus callback ownership."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-cursor-interaction-timing-result.json')
a = p.parse_args()
source = root / 'service/CursorMotionCompletion.swift'
expected = root / 'test/cursor-interaction-timing-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-cursor-interaction-') as tmp:
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', str(source), str(root / 'test/cursor-interaction-timing.swift'),
                    '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(expected), a.report], timeout=15)
record = json.loads(Path(a.report).read_text())
record.update(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),
              production_source_compiled_verbatim=True, native_UI=False,
              scope='Expected readiness decisions after distance calculation versus the production predicate. Lifecycle tests validate the callback owner. No full motion, callbacks, spring, windows or native interactions.')
Path(a.report).write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(result.returncode)
