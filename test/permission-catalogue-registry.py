"""Compare catalogue values to the expected catalogue; exercise weak/reentrant registry."""
from pathlib import Path
import argparse,hashlib,json,resource,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftflags',default='-O');p.add_argument('--artifacts',type=Path);p.add_argument('--native-objects',action='store_true');a=p.parse_args()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=['service/'+n for n in ['PermissionCatalog.swift','SettingsAccessoryCapture.swift','PermissionRowRegistry.swift','PermissionRowRegistryNative.swift']]+['test/permission-catalogue-registry.swift']
objects=['service/SettingsAccessoryCapture.swift','service/PermissionRowRegistry.swift','service/PermissionRowRegistryNative.swift','service/PermissionRowProbes.swift','test/permission-row-probes.swift']
inputs=sorted(set(sources+['test/permission-catalogue-registry.py','test/permission-catalogue-expected.json']+(objects if a.native_objects else [])))
frozen={n:sha(ROOT/n) for n in inputs}
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
with tempfile.TemporaryDirectory(prefix='cua-permission-registry-') as temporary:
    stage=a.artifacts or Path(temporary);stage.mkdir(parents=True,exist_ok=True)
    (stage/'source-snapshot.json').write_text(json.dumps(frozen,indent=2)+'\n')
    binary=stage/'checks';output=stage/'checks-result.json'
    expected=ROOT/'test/permission-catalogue-expected.json'
    command=['swiftc',*shlex.split(a.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-target','arm64-apple-macosx14.4','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/n) for n in sources],'-o',str(binary)]
    with (stage/'build.log').open('w') as out:subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=90)
    with (stage/'run.log').open('w') as out:subprocess.run([str(binary.resolve()),str(expected.resolve()),str(output.resolve())],stdout=out,stderr=subprocess.STDOUT,check=True,timeout=15)
    checks=json.loads(output.read_text());assert checks['passed']
    traps=[]
    for name,extra in [('negative',['--negative']),('overflow',[])]:
        with (stage/('trap-'+name+'.log')).open('w') as out:r=subprocess.run([str(binary.resolve()),'--invalid-window',*extra],stdout=out,stderr=subprocess.STDOUT,timeout=5)
        assert r.returncode in [-4,-5],(name,r.returncode)
        traps.append(dict(name=name,exit_code=r.returncode,passed=True))
    objectResult=None
    if a.native_objects:
        objectBinary=stage/'native-objects';objectOutput=stage/'native-object-result.json'
        objectCommand=command[:command.index(str(ROOT/sources[0]))]+[str(ROOT/n) for n in objects]+['-o',str(objectBinary)]
        with (stage/'native-object-build.log').open('w') as out:subprocess.run(objectCommand,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=90)
        with (stage/'native-object-run.log').open('w') as out:subprocess.run([str(objectBinary.resolve()),str(objectOutput.resolve())],stdout=out,stderr=subprocess.STDOUT,check=True,timeout=15)
        objectResult=json.loads(objectOutput.read_text());assert objectResult['passed']
        objectResult['executable_sha256']=sha(objectBinary)
    assert frozen=={n:sha(ROOT/n) for n in inputs}
    record=dict(passed=True,checks=checks,trap_checks=traps,native_object_checks=objectResult,source_hashes=frozen,source_hashes_recorded_before_compile_and_run=True,executable_sha256=sha(binary),command=command,catalogue_cases=5,native_UI_input_capture_permission_or_power_executed=False)
    (stage/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(dict(passed=True,checks=checks['cases'],trap_checks=len(traps),native_object_checks=objectResult['cases'] if objectResult else 0,catalogue_cases=5)))
