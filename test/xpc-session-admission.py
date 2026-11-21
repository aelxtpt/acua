"""Expected listener admission decisions with owned receivers versus production admission."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-xpc-session-admission-result.json')
a = p.parse_args()
source = root / 'service/XPCSessionAdmission.swift'
expected = root / 'test/xpc-session-admission-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-xpc-admission-') as tmp:
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', str(source), str(root / 'test/xpc-session-admission.swift'),
                    '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(expected), a.report], timeout=15)
record = json.loads(Path(a.report).read_text())
record.update(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),
              production_source_compiled_verbatim=True,
              scope='50 expected admission decisions on an owned NSObject receiver/candidate; only the owned activation method is invoked. Transport/lifecycle tests are separate; no real endpoint, activation or invalidation callback is exercised.')
Path(a.report).write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(result.returncode)
