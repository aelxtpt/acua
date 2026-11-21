from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--swiftc',default='swiftc');parser.add_argument('--swiftflags',default='-O');parser.add_argument('--output',type=Path)
args=parser.parse_args();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=[ROOT/'service/SystemSettingsScalarSpring.swift',ROOT/'service/SystemSettingsSpringAnimation.swift',ROOT/'test/system-settings-animation.swift']
frozen={str(p.relative_to(ROOT)):sha(p) for p in sources}
with tempfile.TemporaryDirectory(prefix='cua-settings-animation-') as directory:
    binary=Path(directory)/'check';result=Path(directory)/'result.json'
    subprocess.run([args.swiftc,*shlex.split(args.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,sources),'-o',str(binary)],check=True,timeout=60)
    check=subprocess.run([str(binary),str(ROOT/'test/system-settings-animation-expected.json'),str(result)],timeout=10)
    record=json.loads(result.read_text())
    driver_sources=[ROOT/'service'/n for n in ['SystemSettingsScalarSpring.swift','SystemSettingsSpringAnimation.swift','SystemSettingsDisplayLinkDriver.swift','SystemSettingsSpringDriverBinding.swift']]+[ROOT/'test/system-settings-display-link.swift']
    driver_hashes={str(p.relative_to(ROOT)):sha(p) for p in driver_sources}
    driver_binary=Path(directory)/'driver';driver_result=Path(directory)/'driver-result.json'
    subprocess.run([args.swiftc,*shlex.split(args.swiftflags),'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-parse-as-library','-module-cache-path','/private/tmp/cua-swift-module-cache',*map(str,driver_sources),'-o',str(driver_binary)],check=True,timeout=60)
    driver_check=subprocess.run([str(driver_binary),str(driver_result)],timeout=10)
    driver_record=json.loads(driver_result.read_text())
    assert driver_hashes=={str(p.relative_to(ROOT)):sha(p) for p in driver_sources}
    record['driver_checks']=driver_record;record['driver_source_hashes']=driver_hashes
assert frozen=={str(p.relative_to(ROOT)):sha(p) for p in sources}
if args.output:
    record.update(source_hashes=frozen,expected_sha256=sha(ROOT/'test/system-settings-animation-expected.json'))
    args.output.write_text(json.dumps(record,indent=2)+'\n')
raise SystemExit(check.returncode or driver_check.returncode)
