"""Exercise real cursor motion methods with owned windows/layers, never AppKit."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/tmp/cua-cursor-motion-driver-result.json')
a = p.parse_args()
source = (ROOT / 'service/CursorOverlay.swift').read_text()

def method(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

markers = ['    func setPressed(', '    private func setPressedMain(', '    func prepareInteraction()', '    func place(', '    func drag(', '    func hide()', '    func press(', '    private func pressMain(',
           '    private func updateTargetWindow(', '    private func onMain(',
           '    private func buildMotionPath(', '    private func bezier(',
           '    private func startSpring(', '    private func step(',
           '    private func placeMain(', '    private func dragMain(',
           '    private func scheduleIdleHide(', '    private func hideMain(']
fragments = '\n\n'.join(method(m) for m in markers)
fixture = (ROOT / 'test/cursor-motion-driver.swift').read_text()
assert fixture.count('/* PRODUCTION_METHODS */') == 1
with tempfile.TemporaryDirectory(prefix='cua-cursor-motion-') as tmp:
    swift = Path(tmp) / 'Fixture.swift'
    swift.write_text(fixture.replace('/* PRODUCTION_METHODS */', fragments))
    binary = Path(tmp) / 'check'
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cua-swift-module-cache',
                    str(ROOT / 'service/CursorMotionCompletion.swift'), str(ROOT / 'service/NativeMouseClick.swift'), str(swift),
                    '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), a.report])
report = json.loads(Path(a.report).read_text())
report.update(source_sha256=hashlib.sha256(source.encode()).hexdigest(),
              fragment_sha256=hashlib.sha256(fragments.encode()).hexdigest(),
              actual_production_methods_compiled_verbatim=markers,
              native_window_or_input_executed=False,
              scope='Real animation, timers, replacement and completion code; owned window, layer, accessibility preference and apply observer providers.')
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
