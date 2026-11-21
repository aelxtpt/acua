"""Compile the actual Actions cursor coordinator with owned no-UI providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--swiftc', default='swiftc')
parser.add_argument('--swiftflags', default='-O -whole-module-optimization')
parser.add_argument('--report', default='/tmp/cua-action-cursor-policy-result.json')
args = parser.parse_args()
source = (ROOT / 'service/Actions.swift').read_text()
start = source.index('enum Actions {')
end = source.index('    // The WindowServer setWindowLocation SPI')
fragment = source[start:end]
fixture = '''
}
extension Actions {
    static func fixtureReset() {
        cursorOwner = nil; cursorRevision = UUID()
    }
    static func fixtureState() -> (String?, UUID) { (cursorOwner, cursorRevision) }
    static func fixtureUpdate(_ bundle: String, enabled: Bool? = nil, _ update: () -> Void) {
        cursor(for: bundle, enabled: enabled, update)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='cua-action-cursor-policy-') as temporary:
    folder = Path(temporary)
    extracted = folder / 'ActionsCursor.swift'
    extracted.write_text('import Foundation\n' + fragment + fixture)
    binary = folder / 'check'
    subprocess.run([args.swiftc, *shlex.split(args.swiftflags), '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cua-swift-module-cache',
                    str(extracted), str(ROOT / 'test/action-cursor-policy.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), args.report])
report = json.loads(Path(args.report).read_text())
report.update(actual_production_fragment_compiled_verbatim=True,
              source_sha256=hashlib.sha256(source.encode()).hexdigest(),
              fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),
              complete_action_dispatch_executed=False,
              provider_scope='CursorCapture and CursorOverlay are owned fixtures; coordinator, ownership, revision and cleanup methods come verbatim from Actions.swift.')
Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
