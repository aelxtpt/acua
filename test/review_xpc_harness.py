"""Run anonymous XPC fixtures against the exact selected service source graph."""
import argparse,hashlib,json,os,shlex,signal,subprocess,tempfile,time
from pathlib import Path
P=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text())
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')

ENTRY='''
// Enter only the owned anonymous-XPC component tests, before ordinary startup.
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--owned-selected-xpc",
      let configured = ProcessInfo.processInfo.environment["CUA_REVIEW_RUN"] else { exit(64) }
// Foundation resolves existing /private/tmp directories to /tmp while an
// absent output file can keep /private/tmp. Canonicalize existing directories
// with the same POSIX operation, then check the fixed output basename.
func xpcCanonicalDirectory(_ path: String) -> String? {
    path.withCString { value in
        guard let pointer = realpath(value, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
guard let xpcReviewRootPath = xpcCanonicalDirectory(configured),
      let xpcReviewTemporaryRoot = xpcCanonicalDirectory("/private/tmp"),
      (xpcReviewRootPath as NSString).deletingLastPathComponent == xpcReviewTemporaryRoot,
      (xpcReviewRootPath as NSString).lastPathComponent.hasPrefix("cua-rv-"),
      let xpcReviewOutputDirectory = xpcCanonicalDirectory((CommandLine.arguments[2] as NSString).deletingLastPathComponent),
      xpcReviewOutputDirectory == xpcReviewRootPath + "/t/xpc",
      (CommandLine.arguments[2] as NSString).lastPathComponent == "result.json" else { exit(64) }
let xpcReviewOutput = URL(fileURLWithPath: xpcReviewOutputDirectory + "/result.json")
_ = NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    var result: [String: Any] = ["passed": false, "physicalInputPosted": false,
        "defaultAppleEventIngressUsed": false, "anonymousXPCFixturesUsed": true]
    do {
        try await ComputerUseXPCTests.main()
        result["passed"] = true
    } catch { result["error"] = String(reflecting: error) }
    do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: xpcReviewOutput) }
    catch { exit(2) }
    exit(result["passed"] as? Bool == true ? 0 : 1)
}
_ = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in exit(124) }
RunLoop.main.run()
exit(4)
'''

def validate_receipt(plan,binary):
 try:
  receipt=read(binary.parent/'build-result.json');normal=read(Path(plan['build_manifest']))
  graph=normal['source_hashes']
  selected=next(n for n in graph if Path(n).name=='ComputerUseXPC.swift')
  return (receipt['selected_manifest_sha256']==sha(Path(plan['build_manifest'])) and
   receipt['binary_sha256']==sha(binary) and receipt['compiled_inputs']==len(graph) and
   receipt['selected_XPC_source']==selected and receipt['selected_XPC_source_sha256']==graph[selected] and
   receipt['test_source_sha256']==sha(P/'test/computer-use-xpc.swift') and
   receipt['builder_source_sha256']==sha(Path(__file__)) and
   all(sha(P/n)==h for n,h in graph.items()) and
   all(sha(binary.parent/n)==h for n,h in receipt['fixture_sources'].items()))
 except (OSError,ValueError,KeyError,StopIteration,TypeError):return False

def build(plan,binary,run):
 manifest=Path(plan['build_manifest']);normal=read(manifest);graph=normal['source_hashes']
 assert normal['exit_code']==0
 assert all(sha(P/n)==h for n,h in {**graph,**normal['configuration_hashes']}.items())
 test_hash=sha(P/'test/computer-use-xpc.swift');builder_hash=sha(Path(__file__))
 command=normal['command'].copy();sources=binary.parent/'sources';sources.mkdir(parents=True)
 selected=next(n for n in graph if Path(n).name=='ComputerUseXPC.swift')
 entry_index=next(i for i,a in enumerate(command) if Path(a).name=='main.swift')
 main=Path(command[entry_index]).read_text();assert main.count('import OSLog\n')==1
 (sources/'main.swift').write_text(main.replace('import OSLog\n','import OSLog\n'+ENTRY,1))
 command[entry_index]=str(sources/'main.swift')
 tests=(P/'test/computer-use-xpc.swift').read_text();assert tests.count('@main enum ComputerUseXPCTests')==1
 (sources/'SelectedXPCTests.swift').write_text(tests.replace('@main enum ComputerUseXPCTests','enum ComputerUseXPCTests',1))
 command.append(str(sources/'SelectedXPCTests.swift'));command[command.index('-o')+1]=str(binary)
 with (binary.parent/'build.log').open('w') as output:
  subprocess.run(command,cwd=P/'service',stdout=output,stderr=subprocess.STDOUT,check=True)
 assert sha(P/'test/computer-use-xpc.swift')==test_hash and sha(Path(__file__))==builder_hash
 assert all(sha(P/n)==h for n,h in {**graph,**normal['configuration_hashes']}.items()),'Build inputs changed during compilation'
 subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','test.acua.review-selected-xpc',str(binary)],check=True)
 receipt=dict(selected_manifest=str(manifest),selected_manifest_sha256=sha(manifest),compiled_inputs=len(graph),
  selected_XPC_source=selected,selected_XPC_source_sha256=graph[selected],command=command,
  test_source_sha256=test_hash,builder_source_sha256=builder_hash,
  fixture_sources={str(p.relative_to(binary.parent)):sha(p) for p in sources.iterdir()},binary_sha256=sha(binary),
  startup='anonymous XPC and owned-provider component fixtures only; ordinary main bypassed',
  selected_XPC_source_compiled_verbatim=True,default_AppleEvent_ingress_or_full_native_dispatch_accepted=False)
 write(binary.parent/'build-result.json',receipt)
 assert validate_receipt(plan,binary)

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run',action='store_true');a=parser.parse_args()
 run=Path(os.environ['CUA_REVIEW_RUN']).resolve(strict=True);plan=read(run/'artifacts.json')
 assert run.parent==Path('/private/tmp') and run.name.startswith('cua-rv-')
 binary=run/'t/xpc/AexComputerUseService';binary.parent.mkdir(exist_ok=True)
 if not binary.exists():build(plan,binary,run)
 assert validate_receipt(plan,binary),'Selected XPC fixture receipt no longer matches the current sources/package'
 if not a.run:print(json.dumps(dict(prepared=True,binary=str(binary))));return 0
 root=Path(tempfile.mkdtemp(prefix='cua-review-startup-',dir='/private/tmp'))
 for n in ['home/.codex','container','tmp']:(root/n).mkdir(parents=True,exist_ok=True)
 q=json.dumps
 profile=('(version 1)\n(allow default)\n(deny appleevent-send)\n(deny network-outbound (remote ip))\n'
  '(deny file-write*)\n'+f'(allow file-write* (subpath {q(str(root))}) (subpath {q(str(run))}) '
  f'(subpath {q(plan["native_temporary_directory"])}) (literal "/dev/null"))\n'+
  f'(deny file-read-data (subpath {q(plan["user_codex_directory"])}))\n')
 (root/'owned-startup.sb').write_text(profile)
 assert sha(Path(plan['boundary_library']))==plan['boundary_sha256']
 env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',TMPDIR=str(root/'tmp'),CUA_REVIEW_RUN=str(run),
  CUA_OWNED_STARTUP_DIRECTORY=str(root),DYLD_INSERT_LIBRARIES=plan['boundary_library'])
 args=['--owned-selected-xpc',str(run/'t/xpc/result.json')]
 process=subprocess.Popen([str(binary),*args],cwd=root,env=env,start_new_session=True)
 receipt=dict(pid=process.pid,group=os.environ['CUA_REVIEW_GROUP'],args=args,owned_directory=str(root),
  service_sha256=plan['service_sha256'],strict_authentication=True,diagnostic=True,
  fixture_binary=str(binary),fixture_binary_sha256=sha(binary),ordinary_service_main_executed=False)
 write(run/'launches'/f'{process.pid}.json',receipt)
 try:code=process.wait(timeout=25)
 except subprocess.TimeoutExpired:
  os.killpg(process.pid,signal.SIGTERM)
  try:code=process.wait(timeout=3)
  except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);code=process.wait(timeout=3)
 write(binary.parent/'execution.json',dict(pid=process.pid,terminal=process.poll() is not None,exit_code=code,
  ordinary_main_executed=False,system_prompt_requested=False,physical_input_posted=False))
 return code
if __name__=='__main__':raise SystemExit(main())
