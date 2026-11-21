"""Verify actual Mach-O/archive/package deployment metadata, without execution."""
from pathlib import Path
import argparse,hashlib,json,plistlib,re,struct

class InvalidDeployment(ValueError):pass
def require(condition,message):
    if not condition:raise InvalidDeployment(message)
def version(text):
    require(isinstance(text,str) and re.fullmatch(r'\d+(?:\.\d+){0,2}',text) is not None,'Invalid version: '+str(text))
    parts=tuple(map(int,text.split('.')));return parts+(0,)*(3-len(parts))
def encoded_version(value):return (value>>16,(value>>8)&255,value&255)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def macho(data,label='Mach-O'):
    require(len(data)>=32 and struct.unpack_from('<I',data)[0]==0xfeedfacf,label+': expected little-endian64-bit Mach-O')
    cpu=struct.unpack_from('<I',data,4)[0];ncmds,size=struct.unpack_from('<II',data,16)
    require(size<=len(data)-32 and ncmds<=size//8,label+': invalid load-command bounds')
    cursor=32;versions=[]
    for _ in range(ncmds):
        require(cursor+8<=32+size,label+': truncated load command')
        command,length=struct.unpack_from('<II',data,cursor)
        require(length>=8 and length%4==0 and cursor+length<=32+size,label+': invalid load-command size')
        if command==0x32:
            require(length>=24,label+': truncated build version')
            platform,minimum,sdk,tools=struct.unpack_from('<IIII',data,cursor+8)
            require(platform==1 and 24+tools*8<=length,label+': invalid macOS build-version command')
            versions.append(dict(minimum=encoded_version(minimum),sdk=encoded_version(sdk),minimum_offset=cursor+12))
        cursor += length
    require(cursor==32+size and len(versions)==1,label+': missing or duplicate build version')
    return dict(cpu=cpu,**versions[0])
def archive(data):
    require(data.startswith(b'!<arch>\n'),'Invalid archive header')
    cursor=8;members=[];long_names=b''
    while cursor<len(data):
        require(cursor+60<=len(data),'Truncated archive member header')
        header=data[cursor:cursor+60];require(header[58:60]==b'`\n','Invalid archive member terminator')
        try:size=int(header[48:58].strip());name=header[:16].decode('ascii').strip()
        except (ValueError,UnicodeError):raise InvalidDeployment('Invalid archive member size/name')
        start=cursor+60;end=start+size;require(size>=0 and end<=len(data),'Invalid archive member bounds')
        body=data[start:end]
        if name.startswith('#1/'):
            try:count=int(name[3:])
            except ValueError:raise InvalidDeployment('Invalid BSD archive name')
            require(0<=count<=size,'Invalid BSD archive name bounds')
            name=body[:count].rstrip(b'\0').decode('utf8',errors='replace');start += count;body=body[count:]
        elif name=='//':long_names=body
        elif name.startswith('/') and name[1:].isdigit():
            position=int(name[1:]);require(position<len(long_names),'Invalid GNU archive name offset')
            name=long_names[position:].split(b'/\n',1)[0].decode('utf8',errors='replace')
        if not (name.startswith('__.SYMDEF') or name in ['/','//']):
            members.append(dict(name=name,offset=start,**macho(body,name)))
        cursor=end+(size%2)
        require(cursor<=len(data),'Missing archive alignment byte')
    require(members,'Archive has no Mach-O objects')
    return members
def payloads(bundle):
    found=[]
    for path in sorted(bundle.rglob('*')):
        if path.is_file() and path.parent.name=='MacOS':found.append(path)
    require(len(found)==3,'Expected service, client and guardian executables')
    return found
def verify(binary,bundle,target,minimum):
    expected=version(minimum);match=re.fullmatch(r'(arm64|x86_64)-apple-macosx(\d+(?:\.\d+){0,2})',target)
    require(match is not None and version(match[2])==expected,'Target/version configuration mismatch')
    cpu={'arm64':0x100000c,'x86_64':0x1000007}[match[1]]
    binary=Path(binary);bundle=Path(bundle)
    metadata=macho(binary.read_bytes(),str(binary))
    require(metadata['cpu']==cpu and metadata['minimum']==expected,'Executable architecture/minimum mismatch')
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    require(isinstance(info,dict),'Invalid bundle property list')
    require(version(info.get('LSMinimumSystemVersion',''))==expected,'Bundle minimum mismatch')
    executable=info.get('CFBundleExecutable');require(isinstance(executable,str) and executable not in ['', '.', '..'] and Path(executable).name==executable,'Invalid bundle executable')
    packaged=macho((bundle/'Contents/MacOS'/executable).read_bytes(),'packaged executable')
    require(packaged['cpu']==cpu and packaged['minimum']==expected,'Packaged executable architecture/minimum mismatch')
    executables=payloads(bundle)
    return dict(passed=True,target=target,minimum=list(expected),SDK=list(metadata['sdk']),
        checked_executables=[path.name for path in executables],
        binary_sha256=digest(binary),packaged_sha256=digest(bundle/'Contents/MacOS'/executable))
def main():
    parser=argparse.ArgumentParser();parser.add_argument('binary',type=Path);parser.add_argument('--bundle',type=Path,required=True)
    parser.add_argument('--target',required=True);parser.add_argument('--minimum',required=True);parser.add_argument('--report',type=Path);args=parser.parse_args()
    try:result=verify(args.binary,args.bundle,args.target,args.minimum)
    except (InvalidDeployment,OSError,ValueError,struct.error) as error:raise SystemExit('FAIL deployment metadata: '+str(error))
    if args.report:args.report.write_text(json.dumps(result,indent=2)+'\n')
    print('PASS deployment metadata: '+args.target+'; checked '+', '.join(result['checked_executables']))
if __name__=='__main__':main()
