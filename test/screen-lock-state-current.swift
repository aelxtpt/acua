import CoreGraphics
import Darwin
import Foundation

private struct Row: Encodable {let name:String;let passed:Bool}
@main private enum UnlockedSessionChecks {
    static func main() throws {
        let uid:uid_t=42
        let key=ScreenLockState.lockedKey,on=ScreenLockState.consoleKey,user=ScreenLockState.userKey,login=ScreenLockState.loginKey
        let own:[String:Any]=[user:42,on:true,login:true]
        func adding(_ base:[String:Any],_ key:String,_ value:Any)->[String:Any]{var b=base;b[key]=value;return b}
        var rows:[Row]=[]
        func check(_ name:String,_ input:[String:Any]?,_ console:[[String:Any]]?,_ expected:ScreenLockState.State,_ consoleExpected:Bool?=nil){
            let result=ScreenLockState.read(currentUID:uid,session:{input},consoleUsers:{console})
            rows.append(.init(name:name,passed:result.state==expected && (consoleExpected==nil || result.onConsole==consoleExpected)))
        }
        check("absent lock key on logged-in own current console is unlocked",own,nil,.unlocked,true)
        check("absent lock key on logged-in own IOConsoleUsers row is unlocked",nil,[own],.unlocked,true)
        check("missing current UID can fall back to verified own logged-in console",[on:true,login:true],[own],.unlocked,true)
        check("inactive rows do not hide the unique own logged-in console",nil,[[user:9,on:false,login:true],own,[user:42,on:false,login:true]],.unlocked,true)
        check("explicit current lock always blocks despite unlocked fallback",adding(own,key,true),[adding(own,key,false)],.locked,true)
        check("explicit current unlocked Boolean remains unlocked",adding(own,key,false),nil,.unlocked,true)
        check("explicit fallback lock remains locked",nil,[adding(own,key,true)],.locked,true)
        check("explicit fallback unlocked Boolean remains unlocked",nil,[adding(own,key,false)],.unlocked,true)
        check("foreign current UID cannot authorize own fallback",[user:9,on:true,login:true],[own],.unavailable)
        check("foreign console user cannot authorize interaction",nil,[[user:9,on:true,login:true]],.unavailable)
        check("missing current UID and no console evidence is unavailable",[on:true,login:true],nil,.unavailable)
        check("missing current login marker does not authorize absent lock key",[user:42,on:true],nil,.unavailable)
        check("missing current on-console marker does not authorize absent lock key",[user:42,login:true],nil,.unavailable)
        check("missing current UID marker does not authorize absent lock key",[on:true,login:true],nil,.unavailable)
        check("absent all session sources remains unavailable",nil,nil,.unavailable)
        check("empty current dictionary cannot authorize interaction",[:],nil,.unavailable)
        check("empty console list cannot authorize interaction",nil,[],.unavailable)
        check("inactive own console remains unavailable",nil,[[user:42,on:false,login:true]],.unavailable,false)
        check("two active own console rows remain unavailable",nil,[own,own],.unavailable)
        check("active foreign console alongside own console remains unavailable",nil,[own,[user:9,on:true,login:true]],.unavailable)
        check("console login not completed remains unavailable",nil,[[user:42,on:true,login:false]],.unavailable,true)
        check("console missing login marker remains unavailable",nil,[[user:42,on:true]],.unavailable,true)
        check("console login string is not a Boolean",nil,[[user:42,on:true,login:"true"]],.unavailable,true)
        check("present null lock marker is distinct from absence",nil,[adding(own,key,NSNull())],.unavailable,true)
        check("present lock string is not an unlocked signal",nil,[adding(own,key,"false")],.unavailable,true)
        check("present numeric zero lock marker remains invalid",nil,[adding(own,key,NSNumber(value:0))],.unavailable,true)
        check("present numeric one lock marker remains invalid",nil,[adding(own,key,NSNumber(value:1))],.unavailable,true)
        check("current present null marker cannot authorize missing-key branch",adding(own,key,NSNull()),nil,.unavailable)
        check("current present string marker cannot authorize missing-key branch",adding(own,key,"false"),nil,.unavailable)
        check("invalid Boolean UID cannot claim the current user",[user:true,on:true,login:true],nil,.unavailable)
        check("negative UID cannot claim the current user",[user:-1,on:true,login:true],nil,.unavailable)
        check("fractional UID cannot claim the current user",[user:42.5,on:true,login:true],nil,.unavailable)
        check("numeric on-console marker cannot authorize missing-key branch",[user:42,on:1,login:true],nil,.unavailable)
        check("numeric login marker cannot authorize missing-key branch",[user:42,on:true,login:1],nil,.unavailable)
        var fallbackReads=0
        let direct=ScreenLockState.read(currentUID:uid,session:{own},consoleUsers:{fallbackReads+=1;return nil})
        rows.append(.init(name:"positive current-session missing-key evidence avoids fallback effects",passed:direct.state == .unlocked && direct.source == .currentSession && fallbackReads==0))
        let passed=rows.allSatisfy(\.passed)
        let report=Result(passed:passed,checks:rows)
        try JSONEncoder().encode(report).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Unlocked-session absence: \(rows.filter(\.passed).count)/\(rows.count)")
        exit(passed ? 0:1)
    }
}
private struct Result: Encodable {
    let passed:Bool
    let checks:[Row]
    let physical_input_focus_or_capture_executed=false
    let full_goal_complete=false
}
