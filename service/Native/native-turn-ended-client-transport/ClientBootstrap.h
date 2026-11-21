#import <Foundation/Foundation.h>
#import <mach/mach.h>

NSXPCListenerEndpoint * _Nullable CUAReceiveBootstrap(
    mach_port_t port, int32_t expectedPID, NSError * _Nullable * _Nullable error);
