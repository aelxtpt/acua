from pathlib import Path
import base64, hashlib, json, os, socket, struct, subprocess, tempfile, time
from codec_wire_fixture import launch

root = Path(__file__).resolve().parent.parent
binary = Path(os.environ.get('CUA_CODEC_BOUNDARY_HARNESS', '/tmp/cua-codec-boundary-harness/AexComputerUseService'))
cases = json.loads((root / 'test/delegated-request-body-corpus.json').read_text())
expected_rows = json.loads((root / 'test/delegated-request-body-expected.json').read_text())['rows']
assert len(cases) == len(expected_rows) == 1166
with tempfile.TemporaryDirectory(prefix='cua-codec-wire-') as temporary:
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
                connection.settimeout(5); connection.connect(endpoint)
                def read(count):
                    data = b''
                    while len(data) < count:
                        chunk = connection.recv(count - len(data)); assert chunk
                        data += chunk
                    return data
                counts = dict(socket=0, native=0)
                for case, expected in zip(cases, expected_rows):
                    assert case['name'] == expected['name']
                    native = case.get('mode') == 'native'
                    if native:
                        message = dict(id=7, jsonrpc='2.0', method='ownedFixtureNativeRequest', params=dict(
                            requestType=case['type'], nativeRequestData=base64.b64encode(case['input'].encode()).decode()))
                        body = json.dumps(message).encode()
                    else:
                        body = case['input'].encode(); message = json.loads(case['input'])
                    connection.sendall(struct.pack('<I', len(body)) + body)
                    length, = struct.unpack('<I', read(4)); assert length <= 8_388_608
                    reply = json.loads(read(length))
                    # The descriptor is decoded before the generic body. Its
                    # deadline type errors keep the -32602 boundary.
                    deadline = message['params'].get('deadlineUnixMilliseconds') if not native else None
                    invalid_deadline = deadline is not None and (isinstance(deadline, bool) or
                        not isinstance(deadline, (int, float)) or int(deadline) != deadline or
                        not -(2**63) <= deadline < 2**63)
                    if invalid_deadline:
                        assert reply.get('error') == dict(code=-32602, message='Invalid params'), (case['name'], reply)
                    elif not native and message['params'].get('deadlineUnixMilliseconds') == 0:
                        assert reply.get('error') == dict(code=-32001, message='Request deadline exceeded'), (case['name'], reply)
                    elif expected['outcome'] != 'decoded':
                        error = dict(code=-10005, message=expected['description']) if native else dict(code=-32602, message='Invalid params')
                        assert reply.get('error') == error, (case['name'], reply, expected)
                    else:
                        assert reply.get('result') == dict(codecValidated=True), (case['name'], reply)
                    counts['native' if native else 'socket'] += 1
                print('PASS framed socket requests preserve socket error envelopes and deadline/typed-body order:', counts['socket'])
                print('PASS fixture-routed native requests preserve typed decoding errors:', counts['native'])
                print('PASS valid decoded requests stop at the fixture boundary before delegated effects')
                record = dict(counts=counts, cases=sum(counts.values()), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    scope='Framed transport plus native dispatch exposed by test-only route; all delegated effects replaced by a marker.',
                    actual_native_mach_xpc_transport=False, native_input_executed=False)
                if output := os.environ.get('CUA_CODEC_BOUNDARY_REPORT'):
                    Path(output).write_text(json.dumps(record, indent=2) + '\n')
        finally:
            service.terminate()
            try: service.wait(timeout=5)
            except subprocess.TimeoutExpired: service.kill(); service.wait()
