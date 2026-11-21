from pathlib import Path
import argparse,hashlib,json,shlex,subprocess,tempfile

ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--swiftflags',default='-O')
parser.add_argument('--report',default='/tmp/cua-offscreen-spi-result.json')
options=parser.parse_args()
source=(ROOT/'service/Capture.swift').read_text()
aliases=[]
for name in ['MainConnection','WindowImages']:
    matches=[line for line in source.splitlines() if line.strip().startswith('private typealias '+name+' =')]
    assert len(matches)==1
    aliases.append(matches[0].replace('    private ','',1))
with tempfile.TemporaryDirectory(prefix='cua-owned-offscreen-abi-') as directory:
    directory=Path(directory)
    bindings=directory/'Bindings.swift'
    bindings.write_text('import Foundation\nimport CoreGraphics\n'+'\n'.join(aliases)+'\n')
    executable=directory/'check';result=directory/'result.json'
    subprocess.run(['swiftc',*shlex.split(options.swiftflags),'-module-cache-path','/private/tmp/cua-swift-module-cache','-o',str(executable),str(bindings),str(ROOT/'test/offscreen-spi-shared.swift'),str(ROOT/'test/offscreen-spi.swift')],check=True,timeout=120)
    subprocess.run([str(executable),str(ROOT/'test/offscreen-spi-corpus.json'),str(result)],check=True,timeout=15)
    actual=json.loads(result.read_text())['cases']
expected=json.loads((ROOT/'test/offscreen-spi-corpus.json').read_text())['expected']
def observable(row):
    # The caller takes only the first image; nil and [] both yield no image.
    return dict(name=row['name'],calls=row['calls'],typedConnectionBits=row['typedConnectionBits'],firstImage=(row['images'] or [None])[0])
assert len(actual)==len(expected)==36
differences=[]
for candidate,wanted in zip(actual,expected):
    if observable(candidate)!=observable(wanted):differences.append(dict(name=wanted['name'],actual=candidate,expected=wanted))
    else:print('PASS offscreen SPI ABI '+wanted['name'])
report=dict(cases=36,matched=36-len(differences),differences=differences,production_bindings_sha256=hashlib.sha256('\n'.join(aliases).encode()).hexdigest(),source='service/Capture.swift',actual_declared_FFI_types_compiled=True,production_capture_body_executed=False,real_screenshots=0,native_input=False)
Path(options.report).write_text(json.dumps(report,indent=2)+'\n')
assert not differences,differences
