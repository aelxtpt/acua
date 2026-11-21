"""Run real selection dispatch/AX wrappers against owned metadata providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--report', default='/tmp/cua-selection-dispatch-result.json')
a = p.parse_args()

def method(path, marker):
    text = (ROOT / path).read_text()
    start = text.index(marker); opening = text.index('{', start)
    depth = 1; end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]

sources = {
    'ACTIONS': ('service/Actions.swift', ['    private static func elementIndex(', '    private static func moveCursor(', '    private static func selectText(']),
    'AX': ('service/AX.swift', ['    static func onElement<', '    static func requireTextSelectionSettable(', '    static func boundsForRange(']),
    'SCROLL': ('service/AXClickableTarget.swift', ['    static func scrollToVisible(']),
    'INDEX': ('service/AXTree.swift', ['    func nativeSelection('])}
fixture = (ROOT / 'test/selection-dispatch.swift').read_text()
hashes = {}
for name, (path, markers) in sources.items():
    fragment = '\n\n'.join(method(path, m) for m in markers)
    assert fixture.count('/* ' + name + ' */') == 1
    fixture = fixture.replace('/* ' + name + ' */', fragment)
    hashes[path] = dict(source_sha256=hashlib.sha256((ROOT / path).read_bytes()).hexdigest(),
                        fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(), markers=markers)
with tempfile.TemporaryDirectory(prefix='cua-selection-dispatch-') as tmp:
    swift = Path(tmp) / 'Fixture.swift'; swift.write_text(fixture)
    binary = Path(tmp) / 'check'
    helpers = ['SelectionCursorPositioning.swift', 'ScrollToVisiblePlan.swift', 'ClickableGeometry.swift', 'TextSelection.swift', 'PendingResult.swift', 'CursorMotionCompletion.swift']
    subprocess.run([a.swiftc, *shlex.split(a.swiftflags), '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cua-swift-module-cache',
                    *[str(ROOT / 'service' / f) for f in helpers], str(swift), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), a.report])
report = json.loads(Path(a.report).read_text())
report.update(actual_production_methods_compiled_verbatim=hashes,
              native_input_or_accessibility_executed=False,
              native_tree_owner_resolution_executed=False,
              scope='Actual Actions selection dispatch, AXIndex selection validation/range/window orchestration, AX self-PID routing, range bounds and scroll plan execution; owned AX storage/statuses, tree owner/snapshot, focus, cursor and request runtime providers. Full NativeAutomationTree owner resolution and scrollArea geometry are outside this fixture.')
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
