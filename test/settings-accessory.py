from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swiftc',default='swiftc');p.add_argument('--swiftflags',default='-O');p.add_argument('--output',type=Path);p.add_argument('--render-output',type=Path);p.add_argument('--skip-render',action='store_true');a=p.parse_args()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
core=['service/SettingsAccessoryCapture.swift','service/SettingsTransitionController.swift','service/SystemSettingsTransitionGeometry.swift']
clock=['service/SystemSettingsScalarSpring.swift','service/SystemSettingsSpringAnimation.swift','service/SystemSettingsDisplayLinkDriver.swift','service/SystemSettingsSpringDriverBinding.swift','service/SystemSettingsTransitionAnimationBinding.swift']
foreground=['service/SystemSettings.swift','service/SettingsAccessoryCapture.swift','service/SystemSettingsAccessoryForeground.swift']
matrix={'controller':core+['test/settings-transition-controller.swift'],'binding':core+clock+['test/settings-transition-binding.swift'],'text':foreground+['test/settings-accessory-text.swift']}
if not a.skip_render:matrix['render']=foreground+['test/settings-accessory-render.swift']
frozen={n:sha(ROOT/n) for n in sorted({n for v in matrix.values() for n in v})}
results={}
with tempfile.TemporaryDirectory(prefix='cua-settings-accessory-') as d:
    d=Path(d)
    for name,sources in matrix.items():
        binary=d/(name+'-checks');result=d/(name+'.json')
        command=[a.swiftc,*shlex.split(a.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*[str(ROOT/n) for n in sources],'-o',str(binary)]
        subprocess.run(command,check=True,timeout=90)
        args=[str(binary)]
        if name=='text':args.append(str(ROOT/'test/settings-accessory-text-expected.json'))
        if name=='render':
            render=a.render_output or d/'render';args += [str(render)];result=render/'result.json'
        else:args.append(str(result))
        subprocess.run(args,check=True,timeout=25)
        results[name]=json.loads(result.read_text());assert results[name]['passed']
assert frozen=={n:sha(ROOT/n) for n in frozen}
record=dict(passed=True,components=results,source_hashes=frozen,expected_sha256=sha(ROOT/'test/settings-accessory-text-expected.json'),nativeRendererExecuted=False)
if a.output:a.output.write_text(json.dumps(record,indent=2)+'\n')
