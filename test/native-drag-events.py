"""Actual factory with real unposted CGEvents versus expected loop/provider data."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/private/tmp/cua-native-drag-events-result.json');a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='cua-native-drag-events-') as tmp:
 binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',str(root/'service/Protocol.swift'),str(root/'service/SynthesizedEventNumberSequence.swift'),str(root/'service/MouseClickEventFactory.swift'),str(root/'test/native-drag-events.swift'),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),str(root/'test/native-drag-events-expected.json'),a.report],timeout=15)
report=json.loads(Path(a.report).read_text());report.update(actual_production_factory_compiled=True,
 source_sha256=hashlib.sha256((root/'service/MouseClickEventFactory.swift').read_bytes()).hexdigest(),
 expected_sha256=hashlib.sha256((root/'test/native-drag-events-expected.json').read_bytes()).hexdigest(),
 scope='Expected drag loop/field values versus the production CGEvent factory. Nine component scenarios, no real event posting/capture/AX.')
Path(a.report).write_text(json.dumps(report,indent=2)+'\n');raise SystemExit(result.returncode)
