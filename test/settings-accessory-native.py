"""Build a bounded owned main that exits before cursor/service initialization."""
from pathlib import Path
import argparse,hashlib,json,re,shlex,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];service=ROOT/'service'
p=argparse.ArgumentParser();p.add_argument('--swiftflags',default='-O');p.add_argument('--output',type=Path);p.add_argument('--artifacts',type=Path);p.add_argument('--build-only',action='store_true');p.add_argument('--async-check',action='store_true');a=p.parse_args()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='cua-settings-native-') as temporary:
    stage=a.artifacts or Path(temporary);stage.mkdir(parents=True,exist_ok=True)
    main=stage/'main.swift';binary=stage/'owned-native-check';result=stage/'run'
    source=(service/'main.swift').read_text();anchor='// Warm the software cursor so the first action shows it immediately.'
    accessory=re.findall(r'\b\w+\.setActivationPolicy\(\.accessory\)',source)
    assert source.count(anchor)==1 and len(accessory)==1
    source=source.replace(accessory[0],accessory[0].replace('.accessory','.prohibited'))
    injected='''do {
    precondition(Thread.isMainThread)
    try MainActor.assumeIsolated { try OwnedSettingsAccessoryNativeChecks.run() }
    exit(0)
} catch {
    fputs("Owned accessory test failed: \\(error)\\n", stderr)
    exit(1)
}
'''
    if a.async_check:
        injected='''do {
    try MainActor.assumeIsolated { try OwnedSettingsAccessoryNativeChecks.run() }
} catch {
    fputs("Owned accessory test failed: \\(error)\\n", stderr)
    exit(1)
}
Task { @MainActor in
    do { try await OwnedLiveSettingsNativeChecks.run();exit(0) }
    catch { fputs("Owned live tracking test failed: \\(error)\\n", stderr);exit(1) }
}
NSApplication.shared.run()
exit(0)
'''
    main.write_text(source.replace(anchor,injected+anchor))
    command=next(shlex.split(l) for l in subprocess.check_output(['make','-n','component-fixture-build','SWIFTFLAGS='+a.swiftflags],cwd=service,text=True).splitlines() if l.startswith('swiftc '))
    command[command.index('main.swift')]=str(main.resolve());command[command.index('-o')+1]=str(binary.resolve());command.append(str(ROOT/'test/settings-accessory-native.swift'))
    if a.async_check:command.append(str(ROOT/'test/settings-live-native.swift'))
    inputs={str((service/x).resolve()):sha((service/x).resolve()) for x in command if x.endswith('.swift')}
    check=[];i=0
    while i<len(command):
        if command[i] in ['-Xlinker','-o']:i+=2;continue
        if not command[i].endswith('.a'):check.append(command[i])
        i+=1
    check.append('-typecheck')
    with (stage/'typecheck.log').open('w') as out:checked=subprocess.run(check,cwd=service,stdout=out,stderr=subprocess.STDOUT,timeout=120)
    if checked.returncode==0:
        with (stage/'build.log').open('w') as out:compiled=subprocess.run(command,cwd=service,stdout=out,stderr=subprocess.STDOUT,timeout=600)
    else:compiled=checked
    record=dict(typecheck_exit_code=checked.returncode,build_exit_code=compiled.returncode,source_hashes=inputs,command=command,temporary_main_exits_before_cursor_and_service=True,production_main_modified=False,native_drag_executed=False)
    if compiled.returncode==0:
        subprocess.run(['codesign','--force','--sign','-','--identifier','test.acua.owned-accessory',str(binary)],check=True,capture_output=True)
        record['executable_sha256']=sha(binary)
        if not a.build_only:
            start=time.monotonic()
            with (stage/'run.log').open('w') as out:
                try:r=subprocess.run([str(binary.resolve()),str(result.resolve())],stdout=out,stderr=subprocess.STDOUT,timeout=30);record['run_exit_code']=r.returncode
                except subprocess.TimeoutExpired:record['run_exit_code']=124
            record['elapsed_seconds']=time.monotonic()-start
            if record['run_exit_code']==0:
                record['checks']=json.loads((result/'result.json').read_text())
                if a.async_check:record['native_checks']=json.loads((result/'native-result.json').read_text())
    assert inputs=={n:sha(Path(n)) for n in inputs}
    if a.artifacts:(stage/'build-result.json').write_text(json.dumps(record,indent=2)+'\n')
    if a.output:a.output.write_text(json.dumps(record,indent=2)+'\n')
    if compiled.returncode:raise SystemExit(compiled.returncode)
    if not a.build_only:raise SystemExit(record['run_exit_code'])
