"""Compile actual pointer context resolution with owned app/window/AX providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-pointer-target-context-result.json');a=p.parse_args()
s=(ROOT/'service/AXPointerTarget.swift').read_text()
def method(marker):
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
fragments={'RESOLVED':method('    struct Resolved {'),'METHODS':'\n'.join(method(m) for m in ['    static func resolve(','    static func resolveContext(']),'FRAMES':'\n'.join(method(m) for m in ['    private static func frame(', '    private static func nativeFrame('])}
f=(ROOT/'test/pointer-target-context.swift').read_text()
for k,v in fragments.items():f=f.replace('/* '+k+' */',v)
with tempfile.TemporaryDirectory(prefix='cua-pointer-context-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(f);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/'service'/n) for n in ['Protocol.swift','ScreenshotGeometry.swift','CaptureLayout.swift','MouseTargeting.swift']],str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report],timeout=30)
r=json.loads(Path(a.report).read_text());r.update(actual_production_methods_compiled_verbatim=True,source_sha256=hashlib.sha256(s.encode()).hexdigest(),fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},native_input=False,scope='Actual resolve/resolveContext and pure MouseTargeting policy. App/window/AX hit, remote/refined routing and current-frame helpers use owned providers. No native AX or WindowServer calls.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
