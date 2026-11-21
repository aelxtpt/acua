"""Compile actual registered-window getters with owned process/observer providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-pointer-window-registry-result.json');a=p.parse_args()
def method(path,marker):
 s=path.read_text();start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
paths={'OBSERVER':'service/AXWindowOrderingObserver.swift','SESSIONS':'service/AXMenuSessions.swift'}
fragments={'MEMBERSHIP':method(ROOT/paths['OBSERVER'],'struct AXWindowMembership'), 'OBSERVER':method(ROOT/paths['OBSERVER'],'    func pointerWindows('),'SESSIONS':method(ROOT/paths['SESSIONS'],'    static func pointerWindows(')}
f=(ROOT/'test/pointer-window-registry.swift').read_text()
for k,v in fragments.items():f=f.replace('/* '+k+' */',v)
with tempfile.TemporaryDirectory(prefix='cua-pointer-registry-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(f);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report],timeout=30)
r=json.loads(Path(a.report).read_text());r.update(actual_production_methods_compiled_verbatim=True,source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths.values()},fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},native_input=False,scope='Actual registry getters and membership, with owned process lookup, validity pruning and stopped lifecycle providers. No real AX/WindowServer/input.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
