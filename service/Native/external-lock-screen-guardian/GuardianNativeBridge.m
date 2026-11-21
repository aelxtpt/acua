#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSError *CUAGuardianError(NSString *domain, NSInteger code, NSString *text) {
    return [NSError errorWithDomain:domain code:code userInfo:@{NSLocalizedDescriptionKey:text}];
}
static void CUAGuardianStoreError(void **output, NSError *error) {
    if (output) *output = error ? (void *)CFBridgingRetain(error) : NULL;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface CUAGuardianMachRendezvous:NSObject
@property(nonatomic,strong) NSMachPort *port;
@property(nonatomic,copy) NSString *name;
- (instancetype)initWithName:(NSString *)name error:(NSError **)error;
- (void)invalidate;
@end
@implementation CUAGuardianMachRendezvous
- (instancetype)initWithName:(NSString *)name error:(NSError **)error {
    if (!(self=[super init])) return nil;
    NSMachPort *port=(NSMachPort *)[NSMachPort port];
    if (!port || port.machPort==0) {
        if (error) *error=CUAGuardianError(@"SAIMachBootstrapRendezvous",1,@"Could not create the Guardian Mach bootstrap rendezvous port.");
        return nil;
    }
    if (![[NSMachBootstrapServer sharedInstance] registerPort:port name:name]) {
        [port invalidate];
        if (error) *error=CUAGuardianError(@"SAIMachBootstrapRendezvous",2,@"Could not register the Guardian Mach bootstrap rendezvous port.");
        return nil;
    }
    _port=port;_name=[name copy];return self;
}
- (void)invalidate {[_port invalidate];_port=nil;}
@end

void *cua_guardian_rendezvous_create(const void *name,void **error) {
    NSError *failure=nil;
    id value=[[CUAGuardianMachRendezvous alloc] initWithName:(__bridge NSString *)name error:&failure];
    CUAGuardianStoreError(error,failure);return value ? (void *)CFBridgingRetain(value):NULL;
}
uint32_t cua_guardian_rendezvous_port(const void *value) {return [(__bridge CUAGuardianMachRendezvous *)value port].machPort;}
void cua_guardian_rendezvous_invalidate(const void *value) {[(__bridge CUAGuardianMachRendezvous *)value invalidate];}
uint32_t cua_guardian_lookup_port(const void *name,void **retainedPort) {
    NSMachPort *port=(NSMachPort *)[[NSMachBootstrapServer sharedInstance] portForName:(__bridge NSString *)name];
    if (retainedPort) *retainedPort=port ? (void *)CFBridgingRetain(port):NULL;
    return port.machPort;
}
#pragma clang diagnostic pop

void *cua_guardian_receive_endpoint(uint32_t port,void **error) {
    typedef int (*Receive)(uint32_t,xpc_object_t __strong *);
    typedef int (*Reply)(xpc_object_t);
    Receive receive=(Receive)dlsym(RTLD_DEFAULT,"xpc_pipe_receive");
    Reply reply=(Reply)dlsym(RTLD_DEFAULT,"xpc_pipe_routine_reply");
    xpc_object_t message=nil;
    if (!receive || receive(port,&message)!=0 || !message) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",3,@"Could not receive XPC endpoint over XPC pipe."));return NULL;
    }
    xpc_object_t raw=xpc_dictionary_get_value(message,"endpoint");
    if (!raw) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",4,@"Could not find XPC endpoint in XPC pipe message."));return NULL;
    }
    NSXPCListenerEndpoint *endpoint=[NSXPCListenerEndpoint new];
    SEL selector=NSSelectorFromString(@"_setEndpoint:");
    if (![endpoint respondsToSelector:selector]) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",4,@"Could not create NSXPC listener endpoint from raw XPC endpoint."));return NULL;
    }
    ((void(*)(id,SEL,id))objc_msgSend)(endpoint,selector,raw);
    xpc_object_t response=xpc_dictionary_create_reply(message);
    if (!response || !reply || reply(response)!=0) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",5,@"Could not reply to NSXPC listener endpoint pipe message."));return NULL;
    }
    return (void *)CFBridgingRetain(endpoint);
}
int cua_guardian_send_endpoint(uint32_t port,const void *value,void **error) {
    NSXPCListenerEndpoint *endpoint=(__bridge NSXPCListenerEndpoint *)value;
    SEL selector=NSSelectorFromString(@"_endpoint");
    id raw=[endpoint respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(endpoint,selector):nil;
    if (!raw) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",4,@"Could not access raw XPC endpoint from NSXPC listener endpoint."));return 0;
    }
    typedef xpc_object_t (*Create)(uint32_t,uint64_t) __attribute__((ns_returns_retained));
    typedef int (*Routine)(xpc_object_t,xpc_object_t,xpc_object_t __strong *);
    Create create=(Create)dlsym(RTLD_DEFAULT,"xpc_pipe_create_from_port");
    Routine routine=(Routine)dlsym(RTLD_DEFAULT,"xpc_pipe_routine");
    xpc_object_t pipe=create ? create(port,0):nil;
    if (!pipe) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",1,@"Could not create XPC pipe from mach port."));return 0;
    }
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0),reply=nil;
    xpc_dictionary_set_value(message,"endpoint",raw);
    if (!routine || routine(pipe,message,&reply)!=0 || !reply) {
        CUAGuardianStoreError(error,CUAGuardianError(@"SAIXPCEndpointTransport",2,@"Could not send XPC endpoint over XPC pipe."));return 0;
    }
    return 1;
}
