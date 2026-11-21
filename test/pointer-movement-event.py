"""Compile real mouse event factory with owned event/source providers; never post."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/tmp/cua-pointer-movement-event-result.json');a=p.parse_args()
s=(ROOT/'service/MouseClickEventFactory.swift').read_text();fragment='\n'.join(l for l in s.splitlines() if not l.startswith('import '));f=(ROOT/'test/pointer-movement-event.swift').read_text().replace('/* FACTORY */',fragment)
with tempfile.TemporaryDirectory(prefix='cua-movement-event-') as tmp:
 swift=Path(tmp)/'Fixture.swift';swift.write_text(f);binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(ROOT/'service/Protocol.swift'),str(ROOT/'service/SynthesizedEventNumberSequence.swift'),str(swift),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),a.report],timeout=30)
r=json.loads(Path(a.report).read_text());r.update(actual_production_factory_compiled_verbatim=True,source_sha256=hashlib.sha256(s.encode()).hexdigest(),fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),native_input=False,scope='Real factory source with owned CGEvent/CGEventSource providers; field writes and allocation failure only. No real events created/posted.')
Path(a.report).write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(result.returncode)
