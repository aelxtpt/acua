"""Shared service permission core with the actual pipeline/window components."""
from pathlib import Path
import argparse, hashlib, json, shlex, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT/'test/fixtures/request-coordination'
p = argparse.ArgumentParser()
p.add_argument('--swiftflags', default='-O')
p.add_argument('--artifacts', type=Path)
a = p.parse_args()
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
shared = ['service/'+n for n in ['Protocol.swift','ServicePermissionTypes.swift','ServiceSystemPermissions.swift']]
matrix = {
    'coordination': shared + ['service/'+n for n in ['RequestPreparation.swift','RequestActivity.swift','SenderRequestContext.swift','ComputerUseTelemetryContext.swift']]
        + ['service/Native/request-coordination/LockScreenAutoUnlockCoordinator.swift',
           'service/Native/service-request-coordination/ServiceAuthenticatedPreparation.swift',
           'service/Native/shared-service-permissions/AuthenticatedRequestPipeline.swift',
           'test/request-coordination.swift'],
    'window': shared + ['service/'+n for n in ['PermissionWindowCoordinator.swift','PermissionWindowServiceAdapter.swift']]
        + ['test/service-permission-window.swift'],
    'edges': shared + ['service/AppshotPermissionResult.swift','service/AppCaptureProtocol.swift','test/service-permissions.swift'],
}
sources = sorted({n for files in matrix.values() for n in files} | {'test/service-permissions.py','service/AppSessions.swift'})
frozen = {n: sha(ROOT/n) for n in sources}
with tempfile.TemporaryDirectory(prefix='cua-shared-permissions-') as temporary:
    stage = (a.artifacts or Path(temporary)).resolve(); stage.mkdir(parents=True, exist_ok=True)
    (stage/'reference').mkdir(exist_ok=True)
    shutil.copy2(FIXTURES/'expected.json',stage/'reference/expected.json')
    shutil.copy2(FIXTURES/'request-traits-C48.json',stage/'request-traits-C48.json')
    ipc = stage/'IPCAppValues.swift'
    ipc.write_text((ROOT/'service/AppSessions.swift').read_text().split('/// Session state is independent')[0])
    results, binaries = {}, {}
    for name, files in matrix.items():
        binary = stage/(name+'-checks')
        command = ['swiftc',*shlex.split(a.swiftflags),'-swift-version','6','-strict-concurrency=complete',
            '-warnings-as-errors','-target','arm64-apple-macosx14.4','-parse-as-library','-module-cache-path',
            '/private/tmp/cua-swift-module-cache',*[str(ROOT/n) for n in files],*([str(ipc)] if name=='edges' else []),'-o',str(binary)]
        with (stage/(name+'-build.log')).open('w') as out:
            subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=120)
        output = stage/'component-result.json' if name=='coordination' else stage/(name+'-result.json')
        with (stage/(name+'-run.log')).open('w') as out:
            subprocess.run([str(binary),str(stage if name=='coordination' else output)],stdout=out,stderr=subprocess.STDOUT,check=True,timeout=30)
        results[name] = json.loads(output.read_text()); assert results[name]['passed']
        binaries[name] = sha(binary)
    assert frozen == {n: sha(ROOT/n) for n in frozen}
    assert results['coordination']['expectedPermissionResultPairs'] == 35
    assert results['coordination']['reusedC48RequestTraitPairs'] == 40
    report = dict(passed=True,source_hashes=frozen,source_hashes_recorded_before_compile_and_run=True,
        components=results,executable_hashes=binaries,
        permission_mapper_vectors_replayed=35,request_traits_replayed=40,
        native_UI_input_desktop_capture_power_or_unlock_executed=False)
    (stage/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({name:len(value['cases']) if isinstance(value['cases'],list) else value['cases'] for name,value in results.items()}))
