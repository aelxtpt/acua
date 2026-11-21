"""Build the physical test gate against the selected package's exact session parser."""
from pathlib import Path
import argparse,hashlib,json,subprocess

from codesign_identity import physical_signing_identity
PROJECT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text())
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--manifest',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
manifest=args.manifest.resolve(strict=True);output=args.output.resolve()
normal=read(manifest);package=read(manifest.parent/'package-build-result.json')
assert package['build_manifest_sha256']==sha(manifest)
matches=[n for n in normal['source_hashes'] if Path(n).name=='ScreenLockState.swift']
assert len(matches)==1
source=PROJECT/matches[0];fixture=PROJECT/'test/physical-session-gate.swift'
assert sha(source)==normal['source_hashes'][matches[0]]
output.parent.mkdir(parents=True,exist_ok=True)
target=normal['command'][normal['command'].index('-target')+1]
inputs={str(source):sha(source),str(fixture):sha(fixture),str(Path(__file__).resolve()):sha(Path(__file__))}
command=['swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',
    '-O','-target',target,'-module-cache-path','/private/tmp/cua-swift-module-cache',
    '-parse-as-library',str(source),str(fixture),'-o',str(output)]
with (output.parent/'build.log').open('w') as log:
    r=subprocess.run(command,cwd=PROJECT,stdout=log,stderr=subprocess.STDOUT,timeout=60)
assert r.returncode==0,'Session gate compilation failed; see build.log'
subprocess.run(['codesign','--force','--sign',physical_signing_identity(),
    '--options','0','--timestamp=none','--identifier','test.acua.pair-gate',str(output)],
    check=True,capture_output=True)
subprocess.run(['codesign','--verify','--strict',str(output)],check=True,capture_output=True)
assert all(sha(Path(n))==h for n,h in inputs.items())
write(output.parent/'build-result.json',dict(build_terminal=True,build_exit_code=0,
    command=command,source_hashes=inputs,selected_parser=matches[0],
    native_manifest_sha256=sha(manifest),package_manifest_sha256=sha(manifest.parent/'package-build-result.json'),
    executable_sha256=sha(output),signature_verified=True,physical_input_executed=False,
    output_distinguishes_locked_from_unavailable=True))
print('Physical gate built from exact selected session parser; no input posted')
