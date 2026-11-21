"""Expected sender capability versus production snapshot/runtime; no native unlock or identity provider."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-sender-request-context-result.json')
a = p.parse_args()
sources = [root / 'service' / n for n in ['Protocol.swift', 'SenderRequestContext.swift', 'RequestRuntime.swift']]
expected = root / 'test/sender-request-context-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-sender-context-') as temporary:
    binary = Path(temporary) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', *map(str, sources),
                    str(root / 'test/sender-request-context.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(expected), a.report], timeout=15)
record = json.loads(Path(a.report).read_text())
record.update(production_sources_compiled_verbatim=True,
              source_hashes={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),
              scope='Auto-unlock predicate on owned identities; snapshot, scope inheritance/restoration, detached workers, cancellation and main-thread handoff. No native signing lookup, login, guardian, lock or unlock.')
Path(a.report).write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(result.returncode)
