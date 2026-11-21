"""Run the production click dispatcher with owned no-UI operation providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--actions', type=Path, default=ROOT / 'service/Actions.swift')
p.add_argument('--key-chord', type=Path, default=ROOT / 'service/KeyChord.swift')
p.add_argument('--observe', action='store_true')
p.add_argument('--preferences', type=Path, default=ROOT / 'service/ComputerUseFeaturePreferences.swift')
p.add_argument('--report', default='/tmp/cua-native-click-policy-result.json')
args = p.parse_args()
source = args.actions.read_text()
begin = source.index('    private static func click(')
end = source.index('    private static func validateAXActionStatus', begin)
def method(marker):
    start=source.index(marker);stop=source.index('{',start)+1;depth=1
    while depth:depth+=(source[stop]=='{')-(source[stop]=='}');stop+=1
    return source[start:stop]
fragment = source[begin:end] + '\n' + method('    private struct SecondaryTarget {') + '\n' + method('    private static func pressSecondaryCursor(')
with tempfile.TemporaryDirectory(prefix='cua-native-click-policy-') as directory:
    folder = Path(directory)
    extracted = folder / 'ActionsClick.swift'
    extracted.write_text('import Foundation\nimport CoreGraphics\nenum Actions {\n' + fragment + '''
    static func fixtureClick(_ input: JSON, native: Bool) throws -> AXSettler.Polling {
        try click(input, bundle: "owned.fixture", native: native)
    }
}
''' + (ROOT / 'test/native-click-policy.swift').read_text())
    binary = folder / 'check'
    subprocess.run([args.swiftc, *shlex.split(args.swiftflags), '-parse-as-library',
        '-module-cache-path', '/private/tmp/cua-swift-module-cache',
        str(ROOT / 'service/Protocol.swift'), str(args.key_chord), str(ROOT / 'service/SecondaryCursorPreparation.swift'),
        str(args.preferences), str(extracted), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), args.report, *(["--observe"] if args.observe else [])])
report = json.loads(Path(args.report).read_text())
report.update(production_click_function_compiled_verbatim=True,
              source_sha256=hashlib.sha256(source.encode()).hexdigest(),
              fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),
              key_chord_source_sha256=hashlib.sha256(args.key_chord.read_bytes()).hexdigest(),
              preference_source_sha256=hashlib.sha256(args.preferences.read_bytes()).hexdigest(),
              provider_scope='Actual click/nativeElementClick, cursor press helper, shared preparation and ClickOptions; owned activation, element, menu, web, visual and delivery providers. No real AX or mouse events.')
Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
