#import "ClientBootstrap.h"
#import <bsm/libbsm.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

@interface NSXPCListenerEndpoint (CUANativeEndpoint)
- (void)_setEndpoint:(xpc_object_t)endpoint;
@end

static NSError *CUABootstrapError(NSString *domain, NSInteger code, NSString *message) {
    return [NSError errorWithDomain:domain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSXPCListenerEndpoint *CUAReceiveBootstrap(mach_port_t port, int32_t expectedPID, NSError **error) {
    typedef int (*Receive)(mach_port_t, xpc_object_t __strong *);
    typedef void (*Audit)(xpc_object_t, audit_token_t *);
    Receive receive = (Receive)dlsym(RTLD_DEFAULT, "xpc_pipe_receive");
    Audit audit = (Audit)dlsym(RTLD_DEFAULT, "xpc_dictionary_get_audit_token");
    xpc_object_t response = nil;
    if (!receive || !audit || receive(port, &response) != 0 || !response) {
        if (error) *error = CUABootstrapError(@"SAIXPCEndpointTransport", 3, @"Could not receive the Computer Use bootstrap response.");
        return nil;
    }
    audit_token_t token = {0};
    audit(response, &token);
    if (audit_token_to_pid(token) != expectedPID) {
        if (error) *error = CUABootstrapError(@"SAIXPCEndpointTransport", 3, @"Computer Use bootstrap response came from an unexpected process.");
        return nil;
    }
    xpc_object_t code = xpc_dictionary_get_value(response, "errorCode");
    if (code && xpc_get_type(code) == XPC_TYPE_INT64) {
        const char *message = xpc_dictionary_get_string(response, "errorMessage");
        if (error) *error = CUABootstrapError(@"ComputerUseIPCXPC", xpc_int64_get_value(code),
            message ? [NSString stringWithUTF8String:message] : @"Computer Use bootstrap failed.");
        return nil;
    }
    xpc_object_t endpoint = xpc_dictionary_get_value(response, "endpoint");
    if (!endpoint || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT) {
        if (error) *error = CUABootstrapError(@"SAIXPCEndpointTransport", 4, @"Computer Use bootstrap response has no XPC endpoint.");
        return nil;
    }
    NSXPCListenerEndpoint *result = [NSXPCListenerEndpoint new];
    [result _setEndpoint:endpoint];
    return result;
}
