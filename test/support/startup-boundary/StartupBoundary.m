#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#import <sandbox.h>

// Test-only library that the review suite inserts into a re-signed copy of the
// service (DYLD_INSERT_LIBRARIES). It runs before the service's own main and
// moves everything the service would write for the user into a temporary
// directory: home, the app group container, user defaults and the lock-screen
// login socket. It also sandboxes the process with the suite's profile and
// writes a JSONL trace of what it redirected. Authentication, request
// dispatch, permissions and native input are never intercepted, so the service
// under test behaves as shipped.
static char rootPath[PATH_MAX], loginDirectory[PATH_MAX], loginSocket[PATH_MAX], tracePath[PATH_MAX];
static BOOL active;
static pid_t initialForeground;
static NSURL *ownedHome, *ownedContainer;
static pthread_mutex_t traceLock = PTHREAD_MUTEX_INITIALIZER;
static void trace(NSDictionary *value) {
    @autoreleasepool {
        NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
        pthread_mutex_lock(&traceLock);
        int fd=open(tracePath,O_WRONLY|O_CREAT|O_APPEND,0600);
        if(fd>=0){write(fd,data.bytes,data.length);write(fd,"\n",1);close(fd);}
        pthread_mutex_unlock(&traceLock);
    }
}
static const char *redirect(const char *path,const char *operation) {
    if(!active || !path)return path;
    const char *mapped=NULL;
    if(!strcmp(path,"/tmp/com.aex.computeruse") || !strcmp(path,"/private/tmp/com.aex.computeruse"))mapped=loginDirectory;
    if(!strcmp(path,"/tmp/com.aex.computeruse/LockScreenLoginAuthorization.sock") ||
       !strcmp(path,"/private/tmp/com.aex.computeruse/LockScreenLoginAuthorization.sock"))mapped=loginSocket;
    if(mapped)trace(@{@"kind":@"login-path",@"operation":@(operation),@"requested":@(path),@"owned":@(mapped)});
    return mapped ?: path;
}
static int owned_mkdir(const char *path,mode_t mode){return mkdir(redirect(path,"mkdir"),mode);}
static int owned_unlink(const char *path){return unlink(redirect(path,"unlink"));}
static int owned_chmod(const char *path,mode_t mode){return chmod(redirect(path,"chmod"),mode);}
static int owned_lstat(const char *path,struct stat *buffer){return lstat(redirect(path,"lstat"),buffer);}
static int owned_bind(int fd,const struct sockaddr *address,socklen_t length) {
    if(active && address && address->sa_family==AF_UNIX && length>offsetof(struct sockaddr_un,sun_path)) {
        const struct sockaddr_un *source=(const struct sockaddr_un *)address;
        const char *mapped=redirect(source->sun_path,"bind");
        if(mapped!=source->sun_path){
            struct sockaddr_un copy={0};copy.sun_family=AF_UNIX;
            size_t count=strlen(mapped);if(count>103){errno=ENAMETOOLONG;return -1;}
            memcpy(copy.sun_path,mapped,count);copy.sun_len=(uint8_t)(count+3);
            return bind(fd,(const struct sockaddr *)&copy,(socklen_t)(count+3));
        }
    }
    return bind(fd,address,length);
}
// dyld interposing: calls to `target` from any image go to `replacement`.
#define INTERPOSE(replacement,target) \
 __attribute__((used,section("__DATA,__interpose"))) static const struct {const void *replacement;const void *target;} interpose_##target={(const void *)(uintptr_t)&replacement,(const void *)(uintptr_t)&target};
INTERPOSE(owned_mkdir,mkdir)
INTERPOSE(owned_unlink,unlink)
INTERPOSE(owned_chmod,chmod)
INTERPOSE(owned_lstat,lstat)
INTERPOSE(owned_bind,bind)

@interface OwnedStartupDefaults:NSUserDefaults
@property NSMutableDictionary *values;
@property NSRecursiveLock *gate;
@end
@implementation OwnedStartupDefaults
- (instancetype)init {
    self=[super initWithSuiteName:@"local.acua.review.volatile-only"];
    if(self){_values=[NSMutableDictionary new];_gate=[NSRecursiveLock new];}
    return self;
}
- (id)objectForKey:(NSString *)key {[_gate lock];id value=_values[key];[_gate unlock];return value;}
- (void)setObject:(id)value forKey:(NSString *)key {
    [_gate lock];if(value)_values[key]=value;else [_values removeObjectForKey:key];[_gate unlock];
    trace(@{@"kind":@"owned-default-write",@"key":key});
}
- (void)setValue:(id)value forKey:(NSString *)key {[self setObject:value forKey:key];}
- (void)removeObjectForKey:(NSString *)key {[self setObject:nil forKey:key];}
- (void)registerDefaults:(NSDictionary *)values {[_gate lock];[_values addEntriesFromDictionary:values];[_gate unlock];}
- (NSString *)stringForKey:(NSString *)key {id v=[self objectForKey:key];return [v isKindOfClass:NSString.class]?v:nil;}
- (NSArray *)arrayForKey:(NSString *)key {id v=[self objectForKey:key];return [v isKindOfClass:NSArray.class]?v:nil;}
- (NSDictionary *)dictionaryForKey:(NSString *)key {id v=[self objectForKey:key];return [v isKindOfClass:NSDictionary.class]?v:nil;}
- (NSData *)dataForKey:(NSString *)key {id v=[self objectForKey:key];return [v isKindOfClass:NSData.class]?v:nil;}
- (BOOL)boolForKey:(NSString *)key {return [[self objectForKey:key] boolValue];}
- (NSInteger)integerForKey:(NSString *)key {return [[self objectForKey:key] integerValue];}
- (double)doubleForKey:(NSString *)key {return [[self objectForKey:key] doubleValue];}
- (float)floatForKey:(NSString *)key {return [[self objectForKey:key] floatValue];}
- (void)setBool:(BOOL)v forKey:(NSString *)key {[self setObject:@(v) forKey:key];}
- (void)setInteger:(NSInteger)v forKey:(NSString *)key {[self setObject:@(v) forKey:key];}
- (void)setDouble:(double)v forKey:(NSString *)key {[self setObject:@(v) forKey:key];}
- (void)setFloat:(float)v forKey:(NSString *)key {[self setObject:@(v) forKey:key];}
- (NSDictionary *)dictionaryRepresentation {[_gate lock];id value=[_values copy];[_gate unlock];return value;}
- (BOOL)synchronize {return YES;}
@end
static OwnedStartupDefaults *ownedDefaults;
static IMP realStringWrite;
static BOOL observedWrite(id object,SEL selector,NSURL *url,BOOL atomic,NSStringEncoding encoding,NSError **error) {
    BOOL result=((BOOL(*)(id,SEL,NSURL*,BOOL,NSStringEncoding,NSError**))realStringWrite)(object,selector,url,atomic,encoding,error);
    if(active && [url.path containsString:@"config.toml"])
        trace(@{@"kind":@"config-write",@"path":url.path,@"atomic":@(atomic),@"succeeded":@(result),
            @"errorDomain":error&&*error?(*error).domain:@"",@"errorCode":error&&*error?@((*error).code):@0});
    return result;
}
static id home(id object,SEL selector){trace(@{@"kind":@"owned-home"});return ownedHome;}
static id container(id object,SEL selector,NSString *identifier){trace(@{@"kind":@"owned-container",@"identifier":identifier});return ownedContainer;}
static id defaults(id object,SEL selector){return ownedDefaults;}
static void processExit(void) {
    @autoreleasepool {
        trace(@{@"kind":@"ordinary-process-exit",@"initialForegroundPID":@(initialForeground),
            @"finalForegroundPID":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)});
    }
}
static void replace(Class klass,SEL selector,IMP implementation) {
    Method method=class_getInstanceMethod(klass,selector);if(!method)_exit(93);
    method_setImplementation(method,implementation);
}
__attribute__((constructor))static void startup(void) {
    @autoreleasepool {
        const char *configured=getenv("CUA_OWNED_STARTUP_DIRECTORY");if(!configured)return;
        // Child processes inherit DYLD_INSERT_LIBRARIES; only the service itself is changed.
        NSString *identifier=NSBundle.mainBundle.bundleIdentifier;
        if(![identifier isEqualToString:@"com.aex.computeruse"])return;
        // Only the review suite's own temporary directories are accepted; the
        // length cap keeps the login socket path within sun_path.
        static const char prefix[]="/private/tmp/cua-review-startup-";
        if(strncmp(configured,prefix,sizeof(prefix)-1) || strlen(configured)>65)_exit(94);
        snprintf(rootPath,sizeof(rootPath),"%s",configured);
        snprintf(loginDirectory,sizeof(loginDirectory),"%s/login",rootPath);
        snprintf(loginSocket,sizeof(loginSocket),"%s/LockScreenLoginAuthorization.sock",loginDirectory);
        snprintf(tracePath,sizeof(tracePath),"%s/boundary.jsonl",rootPath);
        ownedHome=[NSURL fileURLWithPath:[@(rootPath) stringByAppendingPathComponent:@"home"] isDirectory:YES];
        ownedContainer=[NSURL fileURLWithPath:[@(rootPath) stringByAppendingPathComponent:@"container"] isDirectory:YES];
        ownedDefaults=[OwnedStartupDefaults new];
        replace(object_getClass(NSFileManager.defaultManager),@selector(homeDirectoryForCurrentUser),(IMP)home);
        replace(object_getClass(NSFileManager.defaultManager),@selector(containerURLForSecurityApplicationGroupIdentifier:),(IMP)container);
        replace(object_getClass(NSUserDefaults.class),@selector(standardUserDefaults),(IMP)defaults);
        Method stringWrite=class_getInstanceMethod(NSString.class,@selector(writeToURL:atomically:encoding:error:));
        realStringWrite=method_setImplementation(stringWrite,(IMP)observedWrite);
        active=YES;
        NSString *profile=[NSString stringWithContentsOfFile:[@(rootPath) stringByAppendingPathComponent:@"owned-startup.sb"] encoding:NSUTF8StringEncoding error:NULL];
        if(!profile)_exit(95);
        char *error=NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        int result=sandbox_init(profile.UTF8String,0,&error);
        if(result){trace(@{@"kind":@"isolation-failed",@"error":error?@(error):@"unknown"});if(error)sandbox_free_error(error);_exit(96);}
#pragma clang diagnostic pop
        initialForeground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        atexit(processExit);
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            trace(@{@"kind":@"ordinary-did-finish-launching",@"pid":@(getpid()),
                @"initialForegroundPID":@(initialForeground),@"currentForegroundPID":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)});
        }];
        trace(@{@"kind":@"boundary-installed",@"pid":@(getpid()),@"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier,
            @"CODEX_HOME_present":getenv("CODEX_HOME")?@YES:@NO,@"ordinary_main_will_run":@YES,
            @"kernel_file_and_IP_network_isolation_installed":@YES,
            @"auth_dispatch_permissions_or_native_effect_providers_intercepted":@NO});
    }
}
