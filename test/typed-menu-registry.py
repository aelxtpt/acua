"""Actual membership, prune and getters; owned no-UI AX query providers."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--report',default='/private/tmp/cua-typed-menu-registry-result.json');a=p.parse_args()
source=(root/'service/AXWindowOrderingObserver.swift').read_text()
def fragment(marker):
 start=source.index(marker);end=source.index('{',start)+1;depth=1
 while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
pieces={name:fragment(marker) for name,marker in [('MEMBERSHIP','struct AXWindowMembership'),('PRUNE','    func prune('),('POINTER','    func pointerWindows('),('MENU','    func trackMenu(')]}
fixture=(root/'test/typed-menu-registry.swift').read_text()
for name,value in pieces.items():fixture=fixture.replace('/* '+name+' */',value)
with tempfile.TemporaryDirectory(prefix='cua-typed-menu-registry-') as tmp:
 sourcepath=Path(tmp)/'Fixture.swift';sourcepath.write_text(fixture);binary=Path(tmp)/'check'
 subprocess.run(['swiftc','-O','-whole-module-optimization','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(sourcepath),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report],timeout=10)
report=json.loads(Path(a.report).read_text());report.update(actual_production_methods_compiled_verbatim=True,source_sha256=hashlib.sha256(source.encode()).hexdigest(),fragment_sha256={name:hashlib.sha256(value.encode()).hexdigest() for name,value in pieces.items()},native_input=False,native_menu_executed=False)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n');raise SystemExit(result.returncode)
