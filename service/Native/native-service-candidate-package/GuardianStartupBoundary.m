#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <bsm/libbsm.h>
#include <dlfcn.h>
#include <xpc/xpc.h>

// Swift startup landing pads terminate for a foreign Objective-C exception.
// Keep that boundary when the native call goes through this facade;
// otherwise AppKit swallows the exception and leaves an idle helper running.
void cua_guardian_invoke_startup(void (^body)(void)) {
    @try { body(); }
    @catch (NSException *exception) { (void)exception; __builtin_trap(); }
}

// Diagnostic receiver: identical native endpoint extraction/reply, with the
// actual kernel message audit token retained for sender provenance. The normal
// GuardianNativeEndpointTransport receiver remains unchanged.
void *cua_guardian_receive_audited_endpoint(uint32_t port, int32_t *senderPID, void **error) {
    typedef int (*Receive)(uint32_t,xpc_object_t __strong *);
    typedef int (*Reply)(xpc_object_t);
    typedef void (*Audit)(xpc_object_t,audit_token_t *);
    Receive receive=(Receive)dlsym(RTLD_DEFAULT,"xpc_pipe_receive");
    Reply reply=(Reply)dlsym(RTLD_DEFAULT,"xpc_pipe_routine_reply");
    Audit audit=(Audit)dlsym(RTLD_DEFAULT,"xpc_dictionary_get_audit_token");
    xpc_object_t message=nil;
    NSString *failure=nil;
    if (!receive || receive(port,&message)!=0 || !message) failure=@"Native endpoint message was not received";
    if (!failure && !audit) failure=@"Native endpoint audit metadata API is unavailable";
    if (!failure) {
        audit_token_t token={0}; audit(message,&token);
        if (senderPID) *senderPID=(int32_t)token.val[5];
        xpc_object_t raw=xpc_dictionary_get_value(message,"endpoint");
        if (!raw) failure=@"Native endpoint message has no endpoint";
        else {
            NSXPCListenerEndpoint *endpoint=[NSXPCListenerEndpoint new];
            SEL selector=NSSelectorFromString(@"_setEndpoint:");
            if (![endpoint respondsToSelector:selector]) failure=@"Native endpoint cannot be reconstructed";
            else {
                ((void(*)(id,SEL,id))objc_msgSend)(endpoint,selector,raw);
                xpc_object_t response=xpc_dictionary_create_reply(message);
                if (!response || !reply || reply(response)!=0) failure=@"Native endpoint message reply failed";
                else return (void *)CFBridgingRetain(endpoint);
            }
        }
    }
    if (error) *error=(void *)CFBridgingRetain([NSError errorWithDomain:@"OwnedGuardianEndpointAudit" code:1 userInfo:@{NSLocalizedDescriptionKey:failure ?: @"Unknown native endpoint failure"}]);
    return NULL;
}
