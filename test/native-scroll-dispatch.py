"""Compile actual scroll dispatch/state/movement with observable providers that cannot post input."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/private/tmp/cua-native-scroll-dispatch-result.json')
a = p.parse_args()
source = (root / 'service/Actions.swift').read_text()
def method(marker):
    start = source.index(marker); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
markers = ['    private static func elementIndex(', '    private static func recordNativeCursor(',
           '    private static func nativePointerState(', '    private static func nativeMoveMouse(',
           '    private static func nativeScroll(', '    private static func nativeSendScroll(',
           '    private static func nativePointerMovement(']
fragment = '\n'.join(method(m) for m in markers)
fixture = (root / 'test/native-scroll-dispatch.swift').read_text().replace('/* METHODS */', fragment)
with tempfile.TemporaryDirectory(prefix='cua-scroll-dispatch-') as tmp:
    swift = Path(tmp) / 'Fixture.swift'; swift.write_text(fixture); binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cua-swift-module-cache', *[str(root / 'service' / n) for n in
                    ['Protocol.swift', 'NativeScroll.swift', 'ScreenshotGeometry.swift', 'CaptureLayout.swift',
                     'NativeCoordinateConversion.swift', 'SecondaryCursorPreparation.swift',
                     'SynthesizedEventNumberSequence.swift']],
                    str(swift), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), a.report], timeout=30)
report = json.loads(Path(a.report).read_text())
report.update(production_methods_compiled_verbatim=True, source_sha256=hashlib.sha256(source.encode()).hexdigest(),
              fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(), native_input=False,
              scope='Production native scroll orchestration and movement/state helpers; owned AX, cursor, event, focus, target and clock providers. No real window/scroll effects.')
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
