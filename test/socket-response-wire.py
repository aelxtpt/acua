from pathlib import Path
import hashlib, json, os, socket, struct, subprocess, tempfile, time
from codec_wire_fixture import artifact_path, launch

root = Path(__file__).resolve().parent.parent
binary = artifact_path('CUA_CODEC_BOUNDARY_HARNESS', '/tmp/cua-codec-boundary-harness/AexComputerUseService')
corpus = json.loads((root / 'test/socket-response-body-corpus.json').read_text())
passed = 0
with tempfile.TemporaryDirectory(prefix='cua-response-wire-') as temporary:
    endpoint = str(Path(temporary) / 'service.sock')
    env = dict(os.environ, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS='1', CODEX_HOME=temporary)
    with (Path(temporary) / 'service.log').open('wb') as log:
        service = launch(binary, endpoint, env, log)
        try:
            until = time.monotonic() + 10
            while not Path(endpoint).exists():
                assert service.poll() is None and time.monotonic() < until
                time.sleep(.02)
            for case in corpus['cases']:
                frame = json.loads(case['input'])
                frame['params']['ownedRawResponse'] = case['response']
                data = json.dumps(frame).encode()
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(5)
                    connection.connect(endpoint)
                    connection.sendall(struct.pack('<I', len(data)) + data)
                    def read(count):
                        data = b''
                        while len(data) < count:
                            part = connection.recv(count - len(data))
                            if not part:
                                assert not data, 'partial frame'
                                return None
                            data += part
                        return data
                    header = read(4)
                    expected = case['expected']
                    if 'reply' in expected:
                        assert header is not None, case['name']
                        size, = struct.unpack('<I', header)
                        assert json.loads(read(size)) == expected['reply'], case['name']
                    else:
                        assert header is None, case['name']
                passed += 1
        finally:
            service.terminate()
            try: service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill(); service.wait()
record = dict(cases=passed, matched=passed, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
              native_operations_executed=False, fixture_only_reply_injection=True,
              scope='Typed native reply conversion and framed socket EOF on serialization failure; the operation callback is replaced by an owned no-effect boundary.')
artifact_path('CUA_SOCKET_RESPONSE_REPORT', '/tmp/cua-socket-response-wire-result.json').write_text(json.dumps(record, indent=2) + '\n')
print(f'PASS {passed} expected response replies and terminal connection closures')
