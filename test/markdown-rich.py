"""Exercise selected rich-paste sources against scoped conversion goldens."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

P = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
write = lambda p,d: p.write_text(json.dumps(d,indent=2)+"\n")
manifest = Path(os.environ.get("CUA_REVIEW_BUILD_MANIFEST",str(P/"service/.build/current/native-build-result.json"))).resolve(strict=True)
dist = (manifest.parent / "dist").resolve(strict=True)
native = json.loads(manifest.read_text())
paths = ["service/Native/native-paste-rich-conversion/ControllerNativePasteRichConversion.swift",
         "service/MarkdownHTML.swift", "service/Protocol.swift",
         "service/Native/native-paste-engine/ControllerPasteRendering.swift",
         "service/Native/native-paste-engine/ControllerPasteEngine.swift",
         "service/Native/native-selection-paste/ControllerPasteOperation.swift",
         "service/Native/native-paste-transaction/ControllerPasteboardTransaction.swift"]
assert all(name in native["source_hashes"] and sha(P/name) == native["source_hashes"][name] for name in paths)
sources = [P/"test/markdown-rich.swift", *(P/name for name in paths)]
corpus = P/"test/markdown-rich-corpus.json"
frozen = {str(p):sha(p) for p in [*sources,corpus,Path(__file__).resolve(),manifest]}
run = Path(tempfile.mkdtemp(prefix="cua-rich-regression-",dir="/private/tmp"))
print(run,flush=True)
binary = run/"MarkdownRichRegression"
command = ["swiftc","-O","-whole-module-optimization","-swift-version","6","-strict-concurrency=complete",
           "-warnings-as-errors","-parse-as-library","-target","arm64-apple-macosx14.4",
           "-module-cache-path","/private/tmp/cua-swift-module-cache",*map(str,sources),"-o",str(binary)]
with (run/"build.log").open("w") as log:
    build = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=90)
assert build.returncode == 0, (run/"build.log").read_text()
temporary = subprocess.check_output(["getconf","DARWIN_USER_TEMP_DIR"],text=True).strip()
profile = run/"owned.sb"
profile.write_text('(version 1)\n(allow default)\n(deny appleevent-send)\n(deny network-outbound (remote ip))\n'
                   '(deny file-write*)\n(allow file-write* (subpath '+json.dumps(str(run))+') (subpath '+json.dumps(temporary)+') (literal "/dev/null"))\n'
                   '(deny file-read-data (subpath '+json.dumps(str(Path.home()/".codex"))+'))\n')
environment = {k:v for k,v in os.environ.items() if not k.startswith("DYLD_") and k != "CODEX_HOME"}
environment["TMPDIR"] = str(run)
argv = ["/usr/bin/sandbox-exec","-f",str(profile),str(binary),str(corpus),str(run/"result.json")]
with (run/"run.log").open("w") as log:
    process = subprocess.Popen(argv,stdout=log,stderr=subprocess.STDOUT,env=environment)
    try:
        process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(); raise
assert frozen == {name:sha(Path(name)) for name in frozen}
write(run/"build-receipt.json",dict(command=command,source_hashes=frozen,binary_sha256=sha(binary),
      selected_normal_build_manifest=str(manifest),selected_package=str(dist),
      native_component_scope=True,ordinary_service_main_executed=False))
write(run/"execution.json",dict(command=argv,pid=process.pid,exit_code=process.returncode,terminal=True))
log = (run/"run.log").read_text()
print("\n".join(line for line in log.splitlines() if line.startswith("Markdown rich corpus:")) if process.returncode == 0 else log,flush=True)
raise SystemExit(process.returncode)
