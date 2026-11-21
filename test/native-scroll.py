"""Expected component results versus actual production scroll math/CGEvents. No posting."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-native-scroll-result.json')
a = p.parse_args()
sources = ['Protocol.swift', 'NativeScroll.swift', 'ScrollEventFactory.swift', 'ScreenshotGeometry.swift', 'CaptureLayout.swift']
with tempfile.TemporaryDirectory(prefix='cua-native-scroll-') as tmp:
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', *[str(root / 'service' / n) for n in sources],
                    str(root / 'test/native-scroll.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(root / 'test/native-scroll-expected.json'), a.report], timeout=15)
report = json.loads(Path(a.report).read_text())
report.update(production_sources_compiled_verbatim=True,
              source_sha256={n: hashlib.sha256((root / 'service' / n).read_bytes()).hexdigest() for n in sources},
              expected_sha256=hashlib.sha256((root / 'test/native-scroll-expected.json').read_bytes()).hexdigest(),
              scope='56 arithmetic cases, two error values, six unposted wheel factory scenarios; no controller orchestration, native input, AX, capture or real scroll effects.')
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
