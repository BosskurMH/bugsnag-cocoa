//
// Created by Jamie Lynch on 23/03/2018.
// Copyright (c) 2018 Bugsnag. All rights reserved.
//
#import <objc/runtime.h>

#import "Scenario.h"

extern void bsg_kscrash_setPrintTraceToStdout(bool printTraceToStdout);

extern bool bsg_kslog_setLogFilename(const char *filename, bool overwrite);

extern void bsg_i_kslog_logCBasic(const char *fmt, ...) __printflike(1, 2);

void kslog(const char *message) {
    bsg_i_kslog_logCBasic("%s", message);
}

void markErrorHandledCallback(const BSG_KSCrashReportWriter *writer) {
    writer->addBooleanElement(writer, "unhandled", false);
}

// MARK: -

static Scenario *theScenario;

static char ksLogPath[PATH_MAX];

@implementation Scenario {
    dispatch_block_t _onEventDelivery;
}

+ (Scenario *)createScenarioNamed:(NSString *)className
                       withConfig:(BugsnagConfiguration *)config {

    Class clz = NSClassFromString(className);

#if TARGET_OS_IPHONE
    NSString *swiftPrefix = @"iOSTestApp.";
#elif TARGET_OS_OSX
    NSString *swiftPrefix = @"macOSTestApp.";
#endif

    if (!clz) { // Case-insensitive class lookup because AppiumForMac is a bit unreliable at entering uppercase characters.
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name hasPrefix:swiftPrefix]) {
                name = [name substringFromIndex:swiftPrefix.length];
            }
            if ([name caseInsensitiveCompare:className] == NSOrderedSame) {
                clz = classes[i];
                break;
            }
        }
        free(classes);
    }

    if (!clz) {
        [NSException raise:NSInvalidArgumentException format:@"Failed to find scenario class named %@", className];
    }

    id obj = [clz alloc];

    NSAssert([obj isKindOfClass:[Scenario class]], @"Class '%@' is not a subclass of Scenario", className);

    theScenario = obj;

    return [(Scenario *)obj initWithConfig:config];
}

- (instancetype)initWithConfig:(BugsnagConfiguration *)config {
    if (self = [super init]) {
        self.config = config;
    }
    return self;
}

- (void)run {
    // Must be implemented by all subclasses
    [self doesNotRecognizeSelector:_cmd];
}

- (void)startBugsnag {
    [Bugsnag startWithConfiguration:self.config];

    bsg_kscrash_setPrintTraceToStdout(true);
}

- (void)didEnterBackgroundNotification {
}

- (void)performBlockAndWaitForEventDelivery:(dispatch_block_t)block {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    _onEventDelivery = ^{
        dispatch_semaphore_signal(semaphore);
    };
    block();
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)requestDidComplete:(NSURLRequest *)request {
    dispatch_block_t block = _onEventDelivery;
    if (block && [request.URL.absoluteString isEqual:self.config.endpoints.notify]) {
        _onEventDelivery = nil;
        block();
    }
}

// Pointer to the original implementation of -[NSURLSession uploadTaskWithRequest:fromData:completionHandler:]
static NSURLSessionUploadTask * (* NSURLSession_uploadTaskWithRequest_fromData_completionHandler)
 (NSURLSession *session, SEL _cmd, NSURLRequest *request, NSData *fromData, void (^ completionHandler)(NSData *, NSURLResponse *, NSError *));

// Custom implmentation of -[NSURLSession uploadTaskWithRequest:fromData:completionHandler:] to allow tracking when requests finish
static NSURLSessionUploadTask * uploadTaskWithRequest_fromData_completionHandler
 (NSURLSession *session, SEL _cmd, NSURLRequest *request, NSData *fromData, void (^ completionHandler)(NSData *, NSURLResponse *, NSError *)) {
     return NSURLSession_uploadTaskWithRequest_fromData_completionHandler(session, _cmd, request, fromData,
                                                                          ^(NSData *responseData, NSURLResponse *response, NSError *error) {
         completionHandler(responseData, response, error);
         [theScenario requestDidComplete:request];
     });
 }

+ (void)initialize {
    if (self == [Scenario self]) {
#if TARGET_OS_IPHONE
        NSString *logPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                             stringByAppendingPathComponent:@"kscrash.log"];
#else
        NSString *logPath = @"/tmp/kscrash.log";
#endif
        [logPath getFileSystemRepresentation:ksLogPath maxLength:sizeof(ksLogPath)];
        bsg_kslog_setLogFilename(ksLogPath, false);
        
        Method method = class_getInstanceMethod([NSURLSession class], @selector(uploadTaskWithRequest:fromData:completionHandler:));
        NSURLSession_uploadTaskWithRequest_fromData_completionHandler =
        (void *)method_setImplementation(method, (void *)uploadTaskWithRequest_fromData_completionHandler);
    }
}

+ (void)clearPersistentData {
    NSLog(@"Clear persistent data");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    NSString *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSArray<NSString *> *entries = @[
        @"bsg_kvstore",
        @"bsgkv",
        @"bugsnag",
        @"bugsnag_breadcrumbs.json",
        @"bugsnag_handled_crash.txt",
        @"KSCrash",
        @"KSCrashReports"];
    for (NSString *entry in entries) {
        NSString *path = [cachesDir stringByAppendingPathComponent:entry];
        NSError *error = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
            if (![error.domain isEqualToString:NSCocoaErrorDomain] && error.code != NSFileNoSuchFileError) {
                NSLog(@"%@", error);
            }
        }
    }
    NSString *appSupportDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *rootDir = [appSupportDir stringByAppendingPathComponent:@"com.bugsnag.Bugsnag"];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:rootDir error:&error]) {
        if (![error.domain isEqualToString:NSCocoaErrorDomain] && error.code != NSFileNoSuchFileError) {
            NSLog(@"%@", error);
        }
    }
    bsg_kslog_setLogFilename(ksLogPath, true);
}

+ (void)executeMazeRunnerCommand {
    NSURLSession *session = [NSURLSession sessionWithConfiguration:
                             [NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:nil
                                                     delegateQueue:[NSOperationQueue mainQueue]];
    
    // TODO: Change this to port 9339 once Maze Runner implements /command
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://bs-local.com:9009/command"]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] != 200) {
            NSLog(@"%s request failed with %@", __PRETTY_FUNCTION__, response ?: error);
            return;
        }
        NSLog(@"%s response body:  %@", __PRETTY_FUNCTION__, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        
        NSString *action = [command objectForKey:@"action"];
        NSParameterAssert([action isKindOfClass:[NSString class]]);
        
        NSString *scenarioName = [command objectForKey:@"scenario_name"];
        NSParameterAssert([scenarioName isKindOfClass:[NSString class]]);
        
        NSString *eventMode = [command objectForKey:@"scenario_mode"];
        if ([eventMode isKindOfClass:[NSNull class]]) {
            eventMode = nil;
        }
        
        if ([action isEqualToString:@"run_scenario"]) {
            [self runScenario:scenarioName eventMode:eventMode];
        } else if ([action isEqualToString:@"start_bugsnag"]) {
            [self startBugsnagForScenario:scenarioName eventMode:eventMode];
        }
    }] resume];
}

+ (void)runScenario:(NSString *)scenarioName eventMode:(NSString *)eventMode {
    NSLog(@"%s %@ %@", __PRETTY_FUNCTION__, scenarioName, eventMode);
    
    [self startBugsnagForScenario:scenarioName eventMode:eventMode];
    
    NSLog(@"Running scenario \"%@\"", NSStringFromClass([theScenario class]));
    [theScenario run];
}

+ (void)startBugsnagForScenario:(NSString *)scenarioName eventMode:(NSString *)eventMode {
    NSLog(@"%s %@ %@", __PRETTY_FUNCTION__, scenarioName, eventMode);
    
    BugsnagConfiguration *configuration = [[BugsnagConfiguration alloc] initWithApiKey:@"12312312312312312312312312312312"];
    configuration.endpoints.notify = @"http://bs-local.com:9339/notify";
    configuration.endpoints.sessions = @"http://bs-local.com:9339/sessions";
    configuration.enabledErrorTypes.ooms = NO;
    
    theScenario = [Scenario createScenarioNamed:scenarioName withConfig:configuration];
    theScenario.eventMode = eventMode;
    
    NSLog(@"Starting scenario \"%@\"", NSStringFromClass([theScenario class]));
    [theScenario startBugsnag];
}

@end
