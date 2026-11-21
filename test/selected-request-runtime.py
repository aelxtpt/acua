"""Verify async request context against the exact selected source overrides."""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile
P=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest=Path(os.environ.get('CUA_REVIEW_BUILD_MANIFEST',str(P/'service/.build/current/native-build-result.json'))).resolve(strict=True)
normal=json.loads(manifest.read_text());graph=normal['source_hashes']
names=[next(n for n in graph if Path(n).name==base) for base in ['Protocol.swift','SenderRequestContext.swift','RequestRuntime.swift',
 'PendingResult.swift','ComputerUseTelemetryContext.swift','ControllerNativeRequestBridge.swift']]
assert all(sha(P/n)==graph[n] for n in names)
sources=[*(P/n for n in names),P/'test/request-runtime-async.swift']
frozen={str(f):sha(f) for f in [*sources,manifest,Path(__file__).resolve()]}
run=Path(tempfile.mkdtemp(prefix='cua-selected-async-',dir='/private/tmp'));print(run,flush=True)
binary=run/'SelectedAsyncRequestRuntimeChecks'
command=['swiftc','-O','-warnings-as-errors','-enable-upcoming-feature','IsolatedDefaultValues',
 '-parse-as-library','-target','arm64-apple-macosx14.4','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,sources),'-o',str(binary)]
with (run/'build.log').open('w') as output:build=subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,timeout=60)
assert build.returncode==0,(run/'build.log').read_text()
with (run/'run.log').open('w') as output:
 process=subprocess.Popen([str(binary),str(run/'result.json')],stdout=output,stderr=subprocess.STDOUT)
 try:process.wait(timeout=15)
 except subprocess.TimeoutExpired:process.kill();process.wait();raise
assert frozen=={n:sha(Path(n)) for n in frozen}
(run/'build-receipt.json').write_text(json.dumps(dict(command=command,source_hashes=frozen,selected_manifest=str(manifest),
 selected_RequestRuntime_source=names[2],selected_sources_compiled_verbatim=True,binary_sha256=sha(binary)),indent=2)+'\n')
(run/'execution.json').write_text(json.dumps(dict(pid=process.pid,exit_code=process.returncode,terminal=True),indent=2)+'\n')
print((run/'run.log').read_text(),end='',flush=True)
raise SystemExit(process.returncode)
