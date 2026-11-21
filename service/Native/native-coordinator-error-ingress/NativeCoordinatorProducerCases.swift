import EventKit
import Foundation
import SQLite3

struct NativeCoordinatorProducerCase:Sendable {
    let name:String
    let route:String
    let body:Data
    let code:Int32
    let payload:String
    let operation:@Sendable () throws -> Any
    var socketDescription:String {ControllerNativeClientErrorCodec.describe(code:code,payload:payload)}
}
private final class CoordinatorClock:@unchecked Sendable {
    private let lock=NSLock();private var time=Date(timeIntervalSince1970:1000)
    func read()->Date{lock.withLock{time}}
    func advance(_ seconds:TimeInterval){lock.withLock{time.addTimeInterval(seconds)}}
}
@MainActor enum NativeCoordinatorProducerCases {
    static func cases()throws->[NativeCoordinatorProducerCase] {
        func data(_ value:some Encodable)throws->Data {try JSONEncoder().encode(value)}
        func readBody(_ chat:String="owned")throws->Data {
            try data(MessagesIPCReadMessagesRequest(chatGUID:chat,fromDate:nil,toDate:nil,unreadOnly:false,limit:1,cursor:nil))
        }
        func item(_ name:String,_ route:String,_ body:Data,_ code:Int32,_ payload:String,_ operation:@escaping @Sendable ()throws->Any)->NativeCoordinatorProducerCase {
            .init(name:name,route:route,body:body,code:code,payload:payload,operation:operation)
        }
        let noDatabase:@Sendable ()throws->URL = {preconditionFailure("No user or owned database should be opened in these early error cases")}
        let noContact:@Sendable (String)throws->String? = {_ in preconditionFailure("No contact lookup in early error cases")}
        let normal=try readBody(),invalid=try readBody(" \n")
        var values:[NativeCoordinatorProducerCase]=[
            item("messages-pending",MessagesIPCRoute.readMessages.rawValue,normal,-10022,"Messages permission setup is still open",{
                try MessagesIPC.readMessages(request:JSONSerialization.jsonObject(with:normal),permission:{.pending},database:noDatabase,contactName:noContact)
            }),
            item("messages-denied",MessagesIPCRoute.readMessages.rawValue,normal,-10023,"Required Messages permissions were not granted",{
                try MessagesIPC.readMessages(request:JSONSerialization.jsonObject(with:normal),permission:{.denied},database:noDatabase,contactName:noContact)
            }),
            item("messages-invalid-chat",MessagesIPCRoute.readMessages.rawValue,invalid,-10025,"chatGUID must not be empty",{
                try MessagesIPC.readMessages(request:JSONSerialization.jsonObject(with:invalid),permission:{.granted},database:noDatabase,contactName:noContact)
            }),
            item("messages-query-timeout",MessagesIPCRoute.readMessages.rawValue,normal,-10024,"The Messages database query exceeded its time limit",{
                try MessagesIPC.readMessages(request:JSONSerialization.jsonObject(with:normal),permission:{.granted},database:{throw MessagesAttachmentStore.DatabaseError(code:SQLITE_INTERRUPT,message:"owned interrupted query")},contactName:noContact)
            })]
        let search=try data(MessagesIPCSearchMessagesRequest(text:" \n",chatGUIDs:[],participants:[],exactParticipants:false,fromDate:nil,toDate:nil,limit:1,cursor:nil))
        values.append(item("messages-invalid-search",MessagesIPCRoute.searchMessages.rawValue,search,-10025,"text must not be empty",{
            try MessagesIPC.searchMessages(request:JSONSerialization.jsonObject(with:search),permission:{.granted},database:noDatabase,aliases:{_ in preconditionFailure("No contact aliases")},contactName:noContact)
        }))
        let prepare=try data(MessagesIPCPrepareSendRequest(chatGUID:nil,recipients:["Ambiguous"],text:"owned",attachments:[]))
        values.append(item("messages-ambiguous",MessagesIPCRoute.prepareSend.rawValue,prepare,-10026,"recipient matches multiple contacts; retry with an exact phone number or email address",{
            try MessagesIPC.prepareSend(request:JSONSerialization.jsonObject(with:prepare),permission:{.granted},database:noDatabase,matches:{_ in [.init(aliases:["a@example.invalid"],name:nil),.init(aliases:["b@example.invalid"],name:nil)]},contactName:noContact,plans:MessagesSendPlans())
        }))
        let commit=try data(MessagesIPCCommitSendRequest(planID:UUID(),text:"owned"))
        let target=MessagesSendPlans.Target(kind:.existingChat,chatGUID:"owned",displayName:"Owned",participants:[],service:.iMessage)
        for reason in ["missing","expired","already_consumed","rate","uncertain"] {
            let code:Int32=reason=="rate" ? -10029:(reason=="uncertain" ? -10028:-10027)
            let raw=reason=="rate" ? "Messages sending is temporarily rate limited. Try again in 60 seconds.":(reason=="uncertain" ? "Messages could not verify whether the send completed":reason)
            values.append(item("messages-plan-"+reason,MessagesIPCRoute.commitSend.rawValue,commit,code,raw,{
                let clock=CoordinatorClock(),plans=MessagesSendPlans(now:{clock.read()})
                func prepared()throws->MessagesIPCPreparedSend {try plans.prepare(.init(chatGUID:"owned",recipients:[],text:"owned",attachments:[])){_ in target}}
                let id:UUID
                if reason=="missing"{id=UUID()}
                else {
                    if reason=="rate" {
                        for _ in 0..<30{let p=try prepared();_ = try plans.claim(.init(planID:p.planID,text:"owned"),fileCount:0,authorize:{_ in},stage:{_ in ()})}
                    }
                    let p=try prepared();id=p.planID
                    if reason=="expired"{clock.advance(301)}
                    if reason=="already_consumed"{_ = try plans.claim(.init(planID:id,text:"owned"),fileCount:0,authorize:{_ in},stage:{_ in ()})}
                }
                let body=try JSONSerialization.jsonObject(with:JSONEncoder().encode(MessagesIPCCommitSendRequest(planID:id,text:"owned")))
                return try MessagesIPC.commitSend(request:body,files:[],plans:plans,permission:{_ in .granted},deliver:{_,_,_ in
                    guard reason=="uncertain" else{preconditionFailure("No delivery attempt for a rejected plan")}
                    throw CocoaError(.fileWriteUnknown)
                })
            }))
        }
        for status in ["pending","denied","backend-denied","invalid-range"] {
            let route:CalendarOperation.Route=status=="invalid-range" ? .listEvents:.listCalendars
            let body=try status=="invalid-range" ? data(CalendarIPCListEventsRequest(startDate:Date(timeIntervalSince1970:2),endDate:Date(timeIntervalSince1970:1),calendarIDs:[],limit:1,cursor:nil)):data(CalendarIPCListCalendarsRequest())
            let auth:EKAuthorizationStatus=status=="pending" ? .notDetermined:(status=="denied" ? .denied:.fullAccess)
            let gate=CalendarPermissionGate(status:{auth},request:{false})
            let backend=NativeCalendarBackend(makeStore:{preconditionFailure("No EventKit store access for early failures")},access:{status != "backend-denied"})
            let owner=CalendarNativeOwner(backend:backend,permission:gate,locate:{_ in preconditionFailure("No geocoder")})
            let code:Int32=status=="pending" ? -10030:(status=="invalid-range" ? -10032:-10031)
            let raw=status=="pending" ? "Calendar permissions are pending":(status=="invalid-range" ? "The event range must not end before it starts":"Calendar permissions are not granted")
            values.append(item("calendar-"+status,route.rawValue,body,code,raw,{
                try CalendarIPC.perform(route:route,request:JSONSerialization.jsonObject(with:body),owner:{owner})
            }))
        }
        return values
    }
}
