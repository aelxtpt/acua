from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O');p.add_argument('--output',type=Path);a=p.parse_args()
sources=[ROOT/x for x in ['service/SystemSettingsTransitionAppearance.swift','service/SystemSettingsTransitionReplicantView.swift','test/system-settings-appearance.swift','test/system-settings-replicant.swift']]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
frozen={str(p.relative_to(ROOT)):sha(p) for p in sources}
results=[]
with tempfile.TemporaryDirectory(prefix='cua-settings-appearance-') as d:
    d=Path(d)
    for kind in ['appearance','replicant']:
        binary=d/kind;result=d/(kind+'.json')
        selected=[ROOT/'service/SystemSettingsTransitionAppearance.swift',ROOT/('test/system-settings-'+kind+'.swift')]
        if kind=='replicant':selected.insert(1,ROOT/'service/SystemSettingsTransitionReplicantView.swift')
        subprocess.run([a.swiftc,*shlex.split(a.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,selected),'-o',str(binary)],check=True,timeout=60)
        args=[str(binary)]
        if kind=='appearance':args.append(str(ROOT/'test/system-settings-appearance-expected.json'))
        subprocess.run([*args,str(result)],check=True,timeout=15)
        value=json.loads(result.read_text());assert value['passed'];results.append(value)
assert frozen=={str(p.relative_to(ROOT)):sha(p) for p in sources}
record=dict(passed=True,appearance=results[0],owned_offscreen_replicant=results[1],source_hashes=frozen,expected_sha256=sha(ROOT/'test/system-settings-appearance-expected.json'))
if a.output:a.output.write_text(json.dumps(record,indent=2)+'\n')
