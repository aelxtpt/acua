"""Exercise real package metadata, including poisoned copies of the bundle."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,plistlib,shutil,struct,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--bundle',type=Path,required=True)
parser.add_argument('--target',required=True);parser.add_argument('--minimum',required=True);parser.add_argument('--output',type=Path)
args=parser.parse_args();spec=importlib.util.spec_from_file_location('deployment',ROOT/'service/verify_deployment.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();rows=[]
executable_name=plistlib.loads((args.bundle/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
source_paths=[args.binary,args.bundle/'Contents/Info.plist',args.bundle/'Contents/MacOS'/executable_name]
frozen={str(p.resolve()):sha(p) for p in source_paths}
def check(condition,name):
    rows.append(dict(name=name,passed=condition));print(('PASS ' if condition else 'FAIL ')+name)
baseline=module.verify(args.binary,args.bundle,args.target,args.minimum)
check(baseline['passed'] and len(baseline['checked_executables'])==3,'actual service package matches its deployment target')
# The MCP helper sends Apple Events to the service. When a host launches it as
# its own responsible process, macOS refuses those events without a usage text.
client_info=plistlib.loads((args.bundle/'Contents/SharedSupport/AexComputerUseClient.app/Contents/Info.plist').read_bytes())
check(bool(client_info.get('NSAppleEventsUsageDescription')),'MCP helper declares NSAppleEventsUsageDescription')
def reject(name,mutate,reason):
    with tempfile.TemporaryDirectory(prefix='cua-deployment-test-') as directory:
        root=Path(directory);binary=root/'service';bundle=root/'Service.app'
        shutil.copy2(args.binary,binary);shutil.copytree(args.bundle,bundle,symlinks=True)
        mutate(binary,bundle)
        try:module.verify(binary,bundle,args.target,args.minimum);check(False,name)
        except module.InvalidDeployment as error:check(reason in str(error),name)
def packaged(bundle):return bundle/'Contents/MacOS'/plistlib.loads((bundle/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
def change_minimum(path,value):
    data=bytearray(path.read_bytes());metadata=module.macho(data);struct.pack_into('<I',data,metadata['minimum_offset'],value);path.write_bytes(data)
def change_info(bundle,key,value):
    path=bundle/'Contents/Info.plist';info=plistlib.loads(path.read_bytes());info[key]=value;path.write_bytes(plistlib.dumps(info))
reject('reject executable silently compiled for host27',lambda b,p:change_minimum(b,27<<16),'Executable architecture/minimum mismatch')
reject('reject mismatched bundle minimum',lambda b,p:change_info(p,'LSMinimumSystemVersion','27.0'),'Bundle minimum mismatch')
reject('reject non-string bundle minimum',lambda b,p:change_info(p,'LSMinimumSystemVersion',14),'Invalid version')
reject('reject stale newer packaged executable',lambda b,p:change_minimum(packaged(p),27<<16),'Packaged executable architecture/minimum mismatch')
reject('reject bundle executable path escape',lambda b,p:change_info(p,'CFBundleExecutable','../other'),'Invalid bundle executable')
reject('reject a bundle without its helper executables',lambda b,p:shutil.rmtree(p/'Contents/SharedSupport'),'Expected service, client and guardian executables')
def duplicate_command(binary,bundle):
    data=bytearray(binary.read_bytes());count=struct.unpack_from('<I',data,16)[0];cursor=32
    for _ in range(count):
        command,size=struct.unpack_from('<II',data,cursor)
        if command==0x1b:
            require_size=size==24
            if not require_size:raise RuntimeError('unexpected UUID load command size')
            minimum=module.macho(data)['minimum'];value=(minimum[0]<<16)|(minimum[1]<<8)|minimum[2]
            struct.pack_into('<6I',data,cursor,0x32,24,1,value,27<<16,0);binary.write_bytes(data);return
        cursor+=size
    raise RuntimeError('expected real UUID command')
reject('reject ambiguous duplicate build-version commands',duplicate_command,'missing or duplicate build version')
try:module.verify(args.binary,args.bundle,args.target,'99.0');check(False,'reject inconsistent target/version configuration')
except module.InvalidDeployment:check(True,'reject inconsistent target/version configuration')
check(frozen=={str(p.resolve()):sha(p) for p in source_paths},'all mutation cases preserve the actual built package')
result=dict(passed=all(x['passed'] for x in rows),cases=len(rows),results=rows,actual_artifacts=frozen,baseline=baseline,artifacts_executed=False,nativeUIExecuted=False)
if args.output:args.output.write_text(json.dumps(result,indent=2)+'\n')
if not result['passed']:raise SystemExit(1)
