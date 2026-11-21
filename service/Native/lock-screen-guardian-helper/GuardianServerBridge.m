#import <Foundation/Foundation.h>
#import <mach/mach.h>

static uint32_t CUAStoreGuardianLookupError(void **output, NSInteger code, NSString *text) {
    if (output) *output = (void *)CFBridgingRetain([NSError errorWithDomain:@"SAIMachBootstrapRendezvous"
        code:code userInfo:@{NSLocalizedDescriptionKey:text}]);
    return MACH_PORT_NULL;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
uint32_t cua_guardian_copy_send_right(const void *name, void **error) {
    NSPort *port = [[NSMachBootstrapServer sharedInstance] portForName:(__bridge NSString *)name];
    if (!port) return CUAStoreGuardianLookupError(error, 3,
        @"Could not look up the Guardian Mach bootstrap rendezvous port.");
    if (![port isKindOfClass:[NSMachPort class]]) return CUAStoreGuardianLookupError(error, 4,
        @"The Guardian Mach bootstrap rendezvous returned a non-Mach port.");
    mach_port_t right = [(NSMachPort *)port machPort];
    if (mach_port_mod_refs(mach_task_self(), right, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS)
        return CUAStoreGuardianLookupError(error, 5,
            @"Could not retain the Guardian Mach bootstrap rendezvous send right.");
    return right;
}
#pragma clang diagnostic pop

void cua_guardian_deallocate_send_right(uint32_t port) { mach_port_deallocate(mach_task_self(), port); }
