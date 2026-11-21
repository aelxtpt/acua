"""Compile real focus policy, AX adapter and session preparation with owned providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-native-click-focus-result.json');a=p.parse_args()
def method(s,marker):
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
s=(ROOT/'service/SyntheticFocus.swift').read_text();adapter=(ROOT/'service/AXNativeClickFocus.swift').read_text();fixture=(ROOT/'test/native-click-focus.swift').read_text()
fragments={'SESSION':'\n'.join(method(s,m) for m in ['    static func prepare(app:', '    static func clickController(', '    private static func controller(for ']), 'STATE':method(s,'    var clickFocused:'),'ADAPTER':'\n'.join(line for line in adapter.splitlines() if not line.startswith('import '))}
for key,value in fragments.items():fixture=fixture.replace('/* '+key+' */',value)
with tempfile.TemporaryDirectory(prefix='cua-click-focus-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(fixture);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/AXParentChain.swift'),str(ROOT/'service/NativeClickFocusPolicy.swift'),str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report])
r=json.loads(Path(a.report).read_text());r.update(actual_policy_adapter_session_preparation_compiled=True,source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['service/NativeClickFocusPolicy.swift','service/AXNativeClickFocus.swift','service/SyntheticFocus.swift']},fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},scope='Actual focus decisions, bounded selection predicate, whole AX adapter and session prepare/lookup/state getter. Owned AX, app/PID lookup, controller construction/enforcement/window providers; no native event taps or focus transaction executed.',native_input=False)
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
