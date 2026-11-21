"""Compile actual secondary-action selection with owned no-UI providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('--swiftc', default='swiftc')
p.add_argument('--swiftflags', default='-O -whole-module-optimization')
p.add_argument('--actions', type=Path, default=ROOT / 'service/Actions.swift')
p.add_argument('--report', default='/tmp/cua-secondary-action-dispatch-result.json')
p.add_argument('--observe', action='store_true')
a = p.parse_args()
def method(path, marker):
    s = path.read_text(); start = s.index(marker); end = s.index('{', start) + 1; depth = 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}'); end += 1
    return s[start:end]
fragments = {
    'ACTIONS': '\n'.join(method(a.actions,m) for m in ['    private static func elementIndex(', '    private struct SecondaryTarget {', '    private static func secondaryTarget(', '    private static func pressSecondaryCursor(', '    private static func secondary(', '    private static func validateAXActionStatus(']),
    'INDEX': method(ROOT / 'service/AXTree.swift', '    func nativeSecondary(')}
fixture = (ROOT / 'test/secondary-action-dispatch.swift').read_text()
for key,value in fragments.items():
    assert fixture.count('/* '+key+' */') == 1
    fixture = fixture.replace('/* '+key+' */',value)
with tempfile.TemporaryDirectory(prefix='cua-secondary-action-') as temp:
    swift = Path(temp) / 'Fixture.swift'; swift.write_text(fixture); binary = Path(temp) / 'check'
    subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',
        str(ROOT / 'service/Protocol.swift'),str(ROOT / 'service/SecondaryCursorPreparation.swift'),str(swift),'-o',str(binary)],check=True)
    result = subprocess.run([str(binary),str(ROOT / 'test/secondary-action-matching-expected.json'),a.report,*(['--observe'] if a.observe else [])])
report = json.loads(Path(a.report).read_text())
report.update(actual_production_methods_compiled_verbatim=True,
              actions_source_sha256=hashlib.sha256(a.actions.read_bytes()).hexdigest(),
              index_source_sha256=hashlib.sha256((ROOT / 'service/AXTree.swift').read_bytes()).hexdigest(),
              fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},
              native_input_or_AX_executed=False,
              provider_scope='Actual Actions.secondary, target loading, preparation order, press wait parameters, status validation and AXIndex.nativeSecondary. Geometry, awaited movement primitive, cursor window/layer effects, owner/node/snapshot, process validation and action/menu delivery use owned providers; no native effects or full owner resolution are claimed.')
Path(a.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
raise SystemExit(result.returncode)
