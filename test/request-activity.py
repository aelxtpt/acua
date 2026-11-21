"""Compile the production request/activity owner verbatim against expected component results."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-request-activity-result.json')
a = p.parse_args()
sources = [root / 'service/RequestPreparation.swift', root / 'service/RequestActivity.swift']
expected = root / 'test/request-activity-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-request-activity-') as tmp:
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', *map(str, sources),
                    str(root / 'test/request-activity.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(expected), a.report], timeout=15)
report = json.loads(Path(a.report).read_text())
report.update(production_sources_compiled_verbatim=True,
              source_hashes={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),
              scope='40 runtime request conformances; PowerAssertion.acquire uses owned callbacks. Resource matrix, overlapping ownership, reentrancy and cancellation. No global request, lock-screen unlock, real power assertion or native UI acceptance.')
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
