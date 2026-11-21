from pathlib import Path
import hashlib, json, os, socket, struct, subprocess, tempfile, time
from codec_wire_fixture import artifact_path, launch

ROOT = Path(__file__).resolve().parents[1]
STAGE = Path(tempfile.mkdtemp(prefix="cua-runtime-error-results-"))
expected = json.loads((ROOT / 'test/runtime-error-expected.json').read_text())
binary = artifact_path('CUA_CODEC_BOUNDARY_HARNESS', '/tmp/cua-codec-boundary-harness/AexComputerUseService')
rows = []
with tempfile.TemporaryDirectory(prefix='cua-runtime-error-wire-') as temporary:
    endpoint = str(Path(temporary) / 'service.sock')
    env = dict(os.environ, ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS='1', CODEX_HOME=temporary)
    with (STAGE / 'wire-service.stderr.log').open('wb') as log:
        service = launch(binary, endpoint, env, log)
        try:
            until = time.monotonic() + 8
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
                def send(message):
                    body = json.dumps(message).encode()
                    connection.sendall(struct.pack('<I', len(body)) + body)
                    length, = struct.unpack('<I', read(4))
                    assert length <= 8_388_608
                    return json.loads(read(length))
                for index, wanted in enumerate(expected):
                    reply = send({'id': index + 1, 'jsonrpc': '2.0', 'method': 'ownedFixtureNativeRequest',
                                  'params': {'clientApiVersion': 'AcuaComputerUseIPC-5',
                                             'requestType': 'ComputerUseIPCListAppsRequest',
                                             'request': {}, 'ownedFailureCase': index}})
                    assert reply.get('error') == {'code': wanted['code'], 'message': wanted['message']}, (wanted, reply)
                    native = send({'id': index + 101, 'jsonrpc': '2.0', 'method': 'ownedFixtureNativeRequest',
                                   'params': {'clientApiVersion': 'AcuaComputerUseIPC-5',
                                              'requestType': 'ComputerUseIPCListAppsRequest', 'request': {},
                                              'ownedFailureCase': index, 'ownedNativeErrorEnvelope': True}})
                    assert native.get('error') == {'code': wanted['code'], 'message': wanted['native_message']}, (wanted, native)
                    rows.append({'case': wanted['case'], 'error': reply['error'], 'native_error': native['error']})
                    print('PASS exact error envelope:', wanted['case'])
                ping = send({'id': 100, 'jsonrpc': '2.0', 'method': 'ping', 'params': {'clientApiVersion': 'AcuaComputerUseIPC-5'}})
                assert ping['result']['serverApiVersion'] == 'AcuaComputerUseIPC-5'
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()
(STAGE / 'wire-result.json').write_text(json.dumps({'cases': rows, 'matched': len(rows),
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'scope': 'Actual shared socket catch and ComputerUseXPC.requestError with test-only errors; no audio recording, input, or delegated owner.',
    'socket_and_native_error_envelopes_checked': True,
    'installed_service_touched': False, 'native_input_executed': False}, indent=2) + '\n')
print('PASS connection remains usable after all operational errors')

print("RESULT_DIRECTORY", STAGE)
