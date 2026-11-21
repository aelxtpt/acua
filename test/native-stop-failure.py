"""Verify the production stop adapter's error rollback contract."""
from pathlib import Path
import json
import subprocess
import tempfile

P = Path(__file__).resolve().parents[1]
source = P / 'service/Native/native-target-stop-routing/ControllerNativeStop.swift'
with tempfile.TemporaryDirectory(prefix='cua-stop-error-') as directory:
    work = Path(directory)
    binary = work / 'checks'
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                    '-warnings-as-errors', '-target', 'arm64-apple-macosx14.4',
                    '-module-cache-path', '/private/tmp/cua-swift-module-cache', '-parse-as-library',
                    str(source), str(P / 'test/native-stop-failure.swift'), '-o', str(binary)],
                   check=True, timeout=45)
    result = work / 'result.json'
    subprocess.run([str(binary), str(result)], check=True, timeout=10)
    data = json.loads(result.read_text())
    assert data['passed'] and len(data['checks']) == 5
