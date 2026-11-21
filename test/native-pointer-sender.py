"""Compile the real pointer delivery methods with observable, non-posting providers."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-native-pointer-sender-result.json');a=p.parse_args()
s=(ROOT/'service/Actions.swift').read_text()
def method(marker):
    start=s.index(marker);end=s.index('{',start)+1;depth=1
    while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
fragment='\n'.join(method(m) for m in ['    private static func postPointerEvent(', '    private static func postPointerEventUnchecked('])
fixture=(ROOT/'test/native-pointer-sender.swift').read_text().replace('/* METHODS */',fragment)
with tempfile.TemporaryDirectory(prefix='cua-native-sender-') as tmp:
    swift=Path(tmp)/'Fixture.swift';swift.write_text(fixture);binary=Path(tmp)/'check'
    subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/Protocol.swift'),str(ROOT/'service/ScreenshotGeometry.swift'),str(ROOT/'service/CaptureLayout.swift'),str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary),a.report],timeout=30,check=True)
r=json.loads(Path(a.report).read_text());r.update(actual_production_methods_compiled_verbatim=True,source_sha256=hashlib.sha256(s.encode()).hexdigest(),fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),native_input=False,real_events=False,scope='Actual checked/unchecked pointer routing, NSEvent arguments, global/local point fields, timestamp refresh and native PID routing. Owned event factory/SPI/clock/post/identity providers; no AppKit initialization or event posting.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n')
