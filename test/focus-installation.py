"""Compile production focus installers and lifecycle with owned C API providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--controller',type=Path,default=ROOT/'service/SyntheticFocus.swift');p.add_argument('--preventer',type=Path,default=ROOT/'service/FocusStealPreventer.swift');p.add_argument('--matrix-only',action='store_true');p.add_argument('--observe',action='store_true');p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-focus-installation-result.json');a=p.parse_args()
def item(source,marker):
 start=source.index(marker);end=source.index('{',start)+1;depth=1
 while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
controller=a.controller.read_text();preventer=a.preventer.read_text();state=(ROOT/'service/SyntheticFocusEvents.swift').read_text()
fragments={
 'CONTROLLER':'\n'.join(item(controller,m) for m in ['    init(pid:', '    private func refreshActualState(', '    func close()', '    var clickFocused:', '    var isClosed:']),
 'PREVENTER':'\n'.join(item(preventer,m) for m in ['    private final class TapContext {','    private final class Tap {','    private struct Entry {','    private init()', '    static func register(', '    static func unregister(', '    static func isFocused(', '    private func keyboardTap(', '    private func install(', '    private func reenable()', '    private func finish()', '    static var registrationCount:', '    static func hasKeyboardFilter(', '    static func diagnostics()']),
 'STATE':item(state,'struct SyntheticFocusState:')}
fixture=(ROOT/'test/focus-installation.swift').read_text()
for key,value in fragments.items():fixture=fixture.replace('/* '+key+' */',value)
with tempfile.TemporaryDirectory(prefix='cua-focus-install-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(fixture);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/SystemKeyboardFocusState.swift'),str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report,*(['--matrix-only'] if a.matrix_only else []),*(['--observe'] if a.observe else [])])
r=json.loads(Path(a.report).read_text());r.update(actual_production_installers_compiled_verbatim=True,source_sha256={'service/SyntheticFocus.swift':hashlib.sha256(a.controller.read_bytes()).hexdigest(),'service/FocusStealPreventer.swift':hashlib.sha256(a.preventer.read_bytes()).hexdigest(),'service/SyntheticFocusEvents.swift':hashlib.sha256((ROOT/'service/SyntheticFocusEvents.swift').read_bytes()).hexdigest()},fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},native_tap_or_input_used=False,scope='Actual controller init/close/state, persistent filter init/install/register/unregister/reenable/diagnostics and state types. Owned tap/source/run-loop APIs, notifications, process/focus lookup and event delivery; filter and focus transaction are outside this fixture.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
