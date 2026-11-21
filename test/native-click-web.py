"""Run the production web-click predicate with owned ancestry/hit-test providers."""
from pathlib import Path
import argparse, hashlib, json, shlex, subprocess, tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-native-click-web-result.json');a=p.parse_args()
s=(ROOT/'service/Actions.swift').read_text()
def method(marker):
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
fragment='\n'.join(method(m) for m in ['    private static func webClickShape(', '    private static func webClickRequiresMouse('])
fixture=(ROOT/'test/native-click-web.swift').read_text().replace('/* PRODUCTION_METHOD */',fragment)
with tempfile.TemporaryDirectory(prefix='cua-native-web-') as tmp:
    swift=Path(tmp)/'Fixture.swift';swift.write_text(fixture);binary=Path(tmp)/'check'
    subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/AXParentChain.swift'),str(swift),'-o',str(binary)],check=True)
    result=subprocess.run([str(binary),a.report])
r=json.loads(Path(a.report).read_text());r.update(actual_production_web_method_compiled_verbatim=True,source_sha256=hashlib.sha256(s.encode()).hexdigest(),fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),provider_scope='Actual web predicate and bounded parent sequence; owned AX ancestry, app resolution and hit test. No platform AX or native input.',native_input=False)
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
