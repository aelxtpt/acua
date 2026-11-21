"""Exercise the selected SocketIO with actual Darwin descriptor exhaustion."""
import argparse
import array
import json
import os
from pathlib import Path
import resource
import socket
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--helper", required=True)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
inherited = resource.getrlimit(resource.RLIMIT_NOFILE)
assert inherited[0] >= 512, "The controller must have512 descriptors available; its limits are never changed"
rows = []
with open("/dev/null", "rb") as source:
    initial_flags = os.get_inheritable(source.fileno())
    # Adjacent success/failure pairs at the native65 and kernel254 boundaries.
    for count, headroom in [(1, 0), (1, 1), (2, 1), (2, 2), (65, 64), (65, 65), (254, 253), (254, 254)]:
        for location in ["header", "body"]:
            sender, receiver = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            with sender, receiver:
                process = subprocess.Popen(
                    [args.helper, str(receiver.fileno()), str(count), str(headroom), location],
                    pass_fds=(receiver.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                try:
                    header, body = struct.pack("<I", 32), bytes(range(1, 33))
                    rights = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [source.fileno()] * count))]
                    if location == "header":
                        assert sender.sendmsg([header + body], rights) == 36
                    else:
                        sender.sendall(header)
                        assert sender.sendmsg([body], rights) == 32
                    sender.shutdown(socket.SHUT_WR)
                    stdout, stderr = process.communicate(timeout=12)
                except BaseException:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()
                    raise
                observed = json.loads(stdout)
                assert process.returncode == 0 and observed["passed"], (observed, stderr.decode())
                assert (observed["count"], observed["headroom"], observed["location"]) == (count, headroom, location)
                assert os.get_inheritable(source.fileno()) == initial_flags
                os.fstat(source.fileno())
                rows.append(observed)
assert resource.getrlimit(resource.RLIMIT_NOFILE) == inherited
result = dict(passed=True, cases=rows, parent_limits_unchanged=True,
              selected_SocketIO_executed=True,
              native_UI_requests_sent=False)
if args.output:
    args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
