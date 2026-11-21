"""Provider order, expected signature/host inputs, audit cache and explicit development policy."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O -whole-module-optimization');p.add_argument('--report',default='/private/tmp/cua-apple-event-authorization-result.json');a=p.parse_args()
sources=[root/'service'/n for n in ['AppleEventAuthorization.swift','SenderRequestContext.swift','SenderAuthorization.swift']]
expected=root/'test/apple-event-authorization-expected.json'
with tempfile.TemporaryDirectory(prefix='cua-apple-event-auth-') as tmp:
 binary=Path(tmp)/'check'
 subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,sources),str(root/'test/apple-event-authorization.swift'),'-o',str(binary)],check=True)
 result=subprocess.run([str(binary),str(expected),a.report],timeout=15)
record=json.loads(Path(a.report).read_text());record.update(production_sources_compiled_verbatim=True,source_hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},expected_sha256=hashlib.sha256(expected.read_bytes()).hexdigest(),scope='Signature/host decisions on read-only PID metadata plus role/provider-order cases. Native signing callbacks are replaced by owned providers. No real Apple Event transport, authorization grant, GUI or input.')
Path(a.report).write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(result.returncode)
