"""Expected client parser/version decisions versus production snapshot policy; no native automation."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-sender-client-metadata-result.json')
a = p.parse_args()
source = root / 'service/SenderRequestContext.swift'
expected = root / 'test/sender-client-metadata-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-sender-client-metadata-') as tmp:
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
        '/private/tmp/cua-swift-module-cache', str(source), str(root / 'test/sender-client-metadata.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(expected), a.report], timeout=15)
record = json.loads(Path(a.report).read_text())
record.update(production_source_compiled_verbatim=True, source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),
    scope='40 parser/bridge/version inputs with controlled descriptor stringValue; runtime selection; socket and immutable grant snapshot checks. No real Apple Event transport.')
Path(a.report).write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(result.returncode)
