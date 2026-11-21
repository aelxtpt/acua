"""Actual AXIndex lifecycle and native capture coordinator with owned providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/tmp/cua-native-coordinate-state-result.json')
a = p.parse_args()
def method(path, marker):
    text = path.read_text(); start = text.index(marker); end = text.index('{', start) + 1; depth = 1
    while depth: depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
tree = ROOT / 'service/AXTree.swift'
capture = ROOT / 'service/Capture.swift'
actions = ROOT / 'service/Actions.swift'
fragments = {
    'INDEX': '\n'.join(method(tree, m) for m in ['    final class State {', '    func state(', '    func snapshot(', '    struct CoordinateLease {', '    func prepareNativeCoordinates(', '    func updateNativeCoordinates(', '    func nativeCoordinates(', '    func updateNativeCursor(', '    func nativePointerState(', '    private static func clearNativeCoordinates(', '    func publish(', '    func invalidate(', '    func applicationTerminated(', '    func shutdown(', '    private static func releaseImages(']),
    'CAPTURE': '\n'.join(method(tree, m) for m in ['    private static func captureNativeCurrent(', '    static func captureImage(']),
    'PLAN': '\n'.join(method(capture, m) for m in ['    struct NativeGeometryPlan {', '    static func nativeGeometryPlan(', '    private static func screenshotSizing(']),
    'ACTION': method(actions, '    private static func nativeCoordinatePoint('),
}
fixture = (ROOT / 'test/native-coordinate-state.swift').read_text()
for name, text in fragments.items(): fixture = fixture.replace('/* ' + name + ' */', text)
with tempfile.TemporaryDirectory(prefix='cua-native-coordinate-state-') as tmp:
    source = Path(tmp) / 'Fixture.swift'; source.write_text(fixture); binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library', '-module-cache-path', '/private/tmp/cua-swift-module-cache',
                    *[str(ROOT / 'service' / n) for n in ['Protocol.swift', 'ScreenshotGeometry.swift', 'CaptureLayout.swift', 'MouseTargeting.swift','NativeCoordinateConversion.swift']], str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), a.report], timeout=30, check=True)
report = json.loads(Path(a.report).read_text())
report.update(actual_production_methods_compiled_verbatim=True, native_input=False, real_capture=False,
    scope='Actual AXIndex retained-coordinate owner/leases, image/snapshot lifecycle, native capture orchestration, plan creation and action mapping. Owned AX/tree/window/capture/focus/permission providers; no ScreenCaptureKit, native menu clicks, or whole controller execution.',
    source_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [tree, capture, actions, ROOT / 'service/ScreenshotGeometry.swift']},
    fragment_sha256={name: hashlib.sha256(text.encode()).hexdigest() for name, text in fragments.items()})
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
