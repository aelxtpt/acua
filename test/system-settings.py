"""Strict, pure URL comparison against expected before-main results."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization')
p.add_argument('--report',default='/private/tmp/cua-system-settings-result.json');a=p.parse_args()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=[root/'service/SystemSettings.swift',root/'test/system-settings.swift']
frozen={str(p.relative_to(root)):sha(p) for p in sources}
expected=root/'test/system-settings-expected.json';expected_hash=sha(expected)
with tempfile.TemporaryDirectory(prefix='cua-system-settings-') as directory:
    binary=Path(directory)/'check'
    subprocess.run([a.swiftc,'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',*shlex.split(a.swiftflags),
        '-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,sources),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary),str(expected),a.report],check=True,timeout=15)
assert frozen=={str(p.relative_to(root)):sha(p) for p in sources} and sha(expected)==expected_hash
record=json.loads(Path(a.report).read_text());assert record['passed'] and record['expectedURLPairs']==51
record.update(source_hashes=frozen,expected_sha256=expected_hash,
    scope='Fifty-one expected URL helper results including eleven constant destinations and three bad-URL errors. Constant identity is rechecked, not eleven additional helper pairs. Codable/Hashable checks are owned only. No native Settings opening, access, observation or actual permission window is executed.')
Path(a.report).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(dict(passed=True,checks=record['cases'],expected_URL_results=51,nativeSettingsOpened=False)))
