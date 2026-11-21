"""Current-user console parsing, followed optionally by a read-only native snapshot."""
from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftflags',default='-O');p.add_argument('--artifacts',type=Path);p.add_argument('--native',action='store_true');p.add_argument('--manifest',type=Path);a=p.parse_args()
sources=['service/ScreenLockState.swift','test/screen-lock-state.swift']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
if a.manifest:
    manifest=json.loads(a.manifest.read_text())
    selected=[n for n in manifest['source_hashes'] if Path(n).name=='ScreenLockState.swift']
    assert len(selected)==1 and sha(ROOT/selected[0])==manifest['source_hashes'][selected[0]]
    sources[0]=selected[0]
frozen={n:sha(ROOT/n) for n in sources+['test/screen-lock-state.py']}
if a.manifest:frozen['test/screen-lock-state-current.swift']=sha(ROOT/'test/screen-lock-state-current.swift')
with tempfile.TemporaryDirectory(prefix='cua-console-state-') as temporary:
    stage=a.artifacts or Path(temporary);stage.mkdir(parents=True,exist_ok=True)
    binary=stage/'checks'
    command=['swiftc',*shlex.split(a.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-target','arm64-apple-macosx14.4','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/n) for n in sources],'-o',str(binary)]
    with (stage/'build.log').open('w') as out:subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=60)
    result=json.loads(subprocess.check_output([str(binary.resolve())],text=True,timeout=10));assert result['passed']
    if a.manifest:
        current_binary=stage/'checks-current'
        current_command=[str(current_binary) if n==str(binary) else str(ROOT/'test/screen-lock-state-current.swift') if n==str(ROOT/'test/screen-lock-state.swift') else n for n in command]
        with (stage/'current-build.log').open('w') as out:subprocess.run(current_command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=60)
        output=stage/'current-result.json'
        subprocess.run([str(current_binary.resolve()),str(output.resolve())],check=True,capture_output=True,text=True,timeout=10)
        result['current_semantics']=json.loads(output.read_text());assert result['current_semantics']['passed']
        result['selected_manifest_sha256']=sha(a.manifest)
        result['current_command']=current_command
        result['current_executable_sha256']=sha(current_binary)
    if a.native:result['native']=json.loads(subprocess.check_output([str(binary.resolve()),'--native'],text=True,timeout=10))
    assert frozen=={n:sha(ROOT/n) for n in frozen}
    result.update(source_hashes=frozen,source_hashes_recorded_before_compile_and_run=True,command=command,executable_sha256=sha(binary),minimum_target='14.4')
    (stage/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k in ['passed','cases','native']}))
