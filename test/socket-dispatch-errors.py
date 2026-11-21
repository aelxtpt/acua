from pathlib import Path
import hashlib, json, os, socket, struct, subprocess, tempfile
import sys, time
from codec_wire_fixture import launch

ROOT = Path(__file__).resolve().parent.parent
binary = Path(os.environ.get('CUA_SOCKET_DISPATCH_BINARY',
    os.environ.get('CUA_CODEC_BOUNDARY_HARNESS', '/tmp/cua-codec-boundary-harness/AexComputerUseService')))
cases = json.loads((ROOT / 'test/socket-dispatch-error-corpus.json').read_text())
assert len(cases) == 889
differences = []
with tempfile.TemporaryDirectory(prefix='cua-dispatch-wire-') as temporary:
    endpoint = str(Path(temporary) / 'service.sock')
    env = dict(os.environ, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS='1', CODEX_HOME=temporary)
    with (Path(temporary) / 'service.log').open('wb') as log:
        service = launch(binary, endpoint, env, log)
        try:
            until = time.monotonic() + 10
            while not Path(endpoint).exists():
                assert service.poll() is None and time.monotonic() < until
                time.sleep(.02)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(endpoint)
                def read(count):
                    data = b''
                    while len(data) < count:
                        part = connection.recv(count - len(data))
                        assert part
                        data += part
                    return data
                for case in cases:
                    data = case['input'].encode()
                    connection.sendall(struct.pack('<I', len(data)) + data)
                    size, = struct.unpack('<I', read(4))
                    assert size <= 8_388_608
                    reply = json.loads(read(size))
                    expected = case['expected']
                    if reply != expected:
                        differences.append(dict(name=case['name'], expected=expected, actual=reply))
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()
record = dict(cases=len(cases), matched=len(cases) - len(differences), differences=differences,
              binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
              scope='Complete framed replies from the outer socket handler on isolated synthetic connection state; every operation callback is guarded.',
              installed_service_touched=False, native_operations_executed=False,
              native_input_executed=False)
Path(os.environ.get('CUA_SOCKET_DISPATCH_REPORT', '/tmp/cua-socket-dispatch-error-result.json')).write_text(json.dumps(record, indent=2) + '\n')
print(f"Socket outer-handler replies: {record['matched']}/{len(cases)}")
if '--observe' not in sys.argv:
    assert not differences, differences[:3]
    print('PASS exact socket replies for all 40 request types, metadata, expiry, version, unknown routes and IDs')
