"""Run real preparation/point adapter and process policy with owned providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-secondary-preparation-result.json');a=p.parse_args()
source=(ROOT/'service/AXClickableTarget.swift').read_text()
def method(marker):
    start=source.index(marker);end=source.index('{',start)+1;depth=1
    while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
fragment='\n'.join(method(m) for m in ['    private static func point(', '    static func nativePoint(', '    static func secondaryPosition('])
fixture=(ROOT/'test/secondary-preparation.swift').read_text().replace('/* PRODUCTION_POINT_METHODS */',fragment)
with tempfile.TemporaryDirectory(prefix='cua-secondary-preparation-') as temporary:
    swift=Path(temporary)/'Fixture.swift';swift.write_text(fixture);binary=Path(temporary)/'check'
    subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/'service'/n) for n in ['Protocol.swift','ClickableGeometry.swift','SecondaryCursorPreparation.swift','NativeInteractionTargetPolicy.swift']],str(swift),'-o',str(binary)],check=True)
    result=subprocess.run([str(binary),str(ROOT/'test/secondary-preparation-expected.json'),a.report])
d=json.loads(Path(a.report).read_text());d.update(actual_point_methods_compiled_verbatim=True,point_source_sha256=hashlib.sha256(source.encode()).hexdigest(),point_fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),production_whole_helper_and_process_policy_compiled=True,native_UI_or_AX_executed=False,provider_scope='Actual point/secondaryPosition, generic preparation and process policy. Owned AX geometry, ancestry, scroll and NSRunningApplication/PID providers. Live caches, rendering and OS process lookup remain unpaired.')
Path(a.report).write_text(json.dumps(d,indent=2)+'\n');raise SystemExit(result.returncode)
