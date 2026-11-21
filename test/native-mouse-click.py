"""Run real native mouse sequencing and dispatcher with owned event providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-native-mouse-click-result.json');a=p.parse_args()
s=(ROOT/'service/Actions.swift').read_text();start=s.index('    private static func nativeMouseClick(');end=s.index('{',start)+1;depth=1
while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
fragment=s[start:end];fixture=(ROOT/'test/native-mouse-click.swift').read_text().replace('/* PRODUCTION_NATIVE_MOUSE */',fragment)
with tempfile.TemporaryDirectory(prefix='cua-native-mouse-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(fixture);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/Protocol.swift'),str(ROOT/'service/SynthesizedEventNumberSequence.swift'),str(ROOT/'service/KeyChord.swift'),str(ROOT/'service/NativeMouseClick.swift'),str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),str(ROOT/'test/native-mouse-delay-expected.json'),a.report])
r=json.loads(Path(a.report).read_text());r.update(actual_native_mouse_dispatch_compiled_verbatim=True,source_sha256=hashlib.sha256(s.encode()).hexdigest(),fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),timing_source_sha256=hashlib.sha256((ROOT/'service/NativeMouseClick.swift').read_bytes()).hexdigest(),native_input=False,scope='Expected optional-delay outputs versus pure production delay; actual nativeMouseClick, batch construction and sequencing with owned event factory, cursor, post/wait/checkpoint and held-key providers. Native event factory and actual OS posting are not executed by this test.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
