#import "NightShiftBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

// Private ABI, documented by Shifty's CBBlueLightClient header. No Shifty
// implementation is linked or copied. Validate signatures before any invocation.
typedef struct { int hour; int minute; } DDClock;
typedef struct { DDClock start; DDClock end; } DDTimeWindow;
typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunAllowed;
    int mode;
    DDTimeWindow schedule;
    unsigned long long disableFlags;
    BOOL available;
} DDSystemStatus;

@interface DDWarmthClient ()
@property(nonatomic, strong) NSObject *client;
@property(nonatomic, readwrite) BOOL supported;
@property(nonatomic, readwrite, copy) NSString *diagnostic;
@end

@implementation DDWarmthClient
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _diagnostic = @"CoreBrightness is unavailable";
    // Keep the framework loaded for the lifetime of the process.
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return self;
    Class type = NSClassFromString(@"CBBlueLightClient");
    if (!type) return self;
    @try {
        _client = [[type alloc] init];
        NSDictionary *arguments = @{
            @"getStrength:": @[@"^f"],
            @"setStrength:commit:": @[@"f", @(@encode(BOOL))],
            @"setEnabled:": @[@(@encode(BOOL))]
        };
        for (NSString *name in arguments) {
            NSMethodSignature *sig = [_client methodSignatureForSelector:NSSelectorFromString(name)];
            NSArray<NSString *> *types = arguments[name];
            if (!sig || sig.numberOfArguments != types.count + 2 || strcmp(sig.methodReturnType, @encode(BOOL)) != 0) {
                _diagnostic = @"Incompatible Night Shift API version";
                return self;
            }
            for (NSUInteger i = 0; i < types.count; i++) {
                if (strcmp([sig getArgumentTypeAtIndex:i + 2], types[i].UTF8String) != 0) {
                    _diagnostic = @"Night Shift API format has changed";
                    return self;
                }
            }
        }
        NSMethodSignature *statusSig = [_client methodSignatureForSelector:NSSelectorFromString(@"getBlueLightStatus:")];
        if (!statusSig || statusSig.numberOfArguments != 3 || strcmp(statusSig.methodReturnType, @encode(BOOL)) != 0) return self;
        const char *arg = [statusSig getArgumentTypeAtIndex:2];
        if (arg[0] != '^' || arg[1] != '{') return self;
        NSUInteger size = 0, alignment = 0;
        NSGetSizeAndAlignment(arg + 1, &size, &alignment);
        if (size != sizeof(DDSystemStatus) || alignment != __alignof__(DDSystemStatus)) {
            _diagnostic = @"Night Shift status format has changed";
            return self;
        }
        _supported = YES;
        _diagnostic = @"Night Shift API is available";
    } @catch (NSException *exception) {
        _supported = NO;
        _diagnostic = @"Could not connect to Night Shift";
    }
    return self;
}

- (BOOL)invoke:(NSString *)name configure:(void (^)(NSInvocation *))configure {
    if (!_supported || !NSThread.isMainThread) return NO;
    @try {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *sig = [_client methodSignatureForSelector:selector];
        if (!sig) return NO;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = _client;
        call.selector = selector;
        configure(call);
        [call invoke];
        BOOL result = NO;
        [call getReturnValue:&result];
        return result;
    } @catch (NSException *exception) {
        _supported = NO;
        _diagnostic = @"Night Shift API stopped responding";
        return NO;
    }
}

- (NSDictionary<NSString *, NSNumber *> *)readState {
    __block DDSystemStatus status = {0};
    __block float strength = 0;
    BOOL statusOK = [self invoke:@"getBlueLightStatus:" configure:^(NSInvocation *call) {
        DDSystemStatus *pointer = &status;
        [call setArgument:&pointer atIndex:2];
    }];
    BOOL strengthOK = [self invoke:@"getStrength:" configure:^(NSInvocation *call) {
        float *pointer = &strength;
        [call setArgument:&pointer atIndex:2];
    }];
    if (!statusOK || !strengthOK || !isfinite(strength) || strength < 0 || strength > 1) return nil;
    return @{@"enabled": @(status.enabled), @"active": @(status.active),
             @"available": @(status.available), @"strength": @(strength)};
}

- (BOOL)changeEnabled:(BOOL)enabled {
    NSDictionary *state = [self readState];
    if (!state || ![state[@"available"] boolValue]) return NO;
    return [self invoke:@"setEnabled:" configure:^(NSInvocation *call) {
        BOOL value = enabled;
        [call setArgument:&value atIndex:2];
    }];
}

- (BOOL)changeStrength:(float)strength {
    if (!isfinite(strength) || strength < 0 || strength > 1) return NO;
    NSDictionary *state = [self readState];
    if (!state || ![state[@"available"] boolValue]) return NO;
    return [self invoke:@"setStrength:commit:" configure:^(NSInvocation *call) {
        float value = strength;
        BOOL commit = YES;
        [call setArgument:&value atIndex:2];
        [call setArgument:&commit atIndex:3];
    }];
}
@end
