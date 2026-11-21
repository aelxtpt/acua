"""Actual coordinate coordinator with owned no-UI providers; not a native integration run."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-coordinate-click-result.json');a=p.parse_args()
def method(path,marker):
 s=path.read_text();start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
actions=ROOT/'service/Actions.swift'
fragments={'ACTIONS':'\n'.join(method(actions,m) for m in ['    private static func snapshot(', '    private static func nativeCoordinatePoint(', '    private static func coordinateSnapshot(', '    private static func nativeCoordinateClick(', '    private static func nativeCoordinateAction(', '    private static func nativeDrag(', '    private static func nativePointerMovement(', '    private static func recordNativeCursor(']), 'POLICY':'\n'.join(l for l in (ROOT/'service/NativeInteractionTargetPolicy.swift').read_text().splitlines() if not l.startswith('import '))}
f=(ROOT/'test/coordinate-click.swift').read_text()
for k,v in fragments.items():f=f.replace('/* '+k+' */',v)
with tempfile.TemporaryDirectory(prefix='cua-coordinate-click-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(f);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/'service'/n) for n in ['SynthesizedEventNumberSequence.swift','Protocol.swift','KeyChord.swift','ScreenshotGeometry.swift','CaptureLayout.swift','NativeMenuClick.swift','NativeCoordinateConversion.swift','CursorMotionCompletion.swift']],str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report],timeout=30)
r=json.loads(Path(a.report).read_text());r.update(actual_production_methods_compiled_verbatim=True,source_sha256={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ['service/Actions.swift','service/NativeInteractionTargetPolicy.swift','service/ScreenshotGeometry.swift','service/KeyChord.swift']},fragment_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},native_input=False,scope='Actual coordinate preparation, snapshot freshness/raise control, PID policy, move event sequencing and coordinate mapping. Owned app/window/hit/visual/focus/delivery/event factory providers; no native movement, event posting, capture or taps.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
