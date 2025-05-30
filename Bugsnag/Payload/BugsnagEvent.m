//
//  BugsnagEvent.m
//  Bugsnag
//
//  Created by Simon Maynard on 11/26/14.
//
//

#import "BugsnagEvent+Private.h"

#import "BSGDefines.h"
#import "BSGMemoryFeatureFlagStore.h"
#import "BSGJSONSerialization.h"
#import "BSGKeys.h"
#import "BSGSerialization.h"
#import "BSGUtils.h"
#import "BSG_KSCrashReportFields.h"
#import "BSG_RFC3339DateTool.h"
#import "Bugsnag+Private.h"
#import "BugsnagApp+Private.h"
#import "BugsnagAppWithState+Private.h"
#import "BugsnagBreadcrumb+Private.h"
#import "BugsnagBreadcrumbs.h"
#import "BugsnagCollections.h"
#import "BugsnagConfiguration+Private.h"
#import "BugsnagDeviceWithState+Private.h"
#import "BugsnagError+Private.h"
#import "BugsnagHandledState.h"
#import "BugsnagMetadata+Private.h"
#import "BugsnagLogger.h"
#import "BugsnagSession+Private.h"
#import "BugsnagStackframe+Private.h"
#import "BugsnagStacktrace.h"
#import "BugsnagThread+Private.h"
#import "BugsnagUser+Private.h"
#import "BSGFileLocations.h"

static NSString * const RedactedMetadataValue = @"[REDACTED]";

id BSGLoadConfigValue(NSDictionary *report, NSString *valueName) {
    NSString *keypath = [NSString stringWithFormat:@"user.config.%@", valueName];
    NSString *fallbackKeypath = [NSString stringWithFormat:@"user.config.config.%@", valueName];

    return [report valueForKeyPath:keypath]
    ?: [report valueForKeyPath:fallbackKeypath]; // some custom values are nested
}

/**
 * Attempt to find a context (within which the event is being reported)
 * This can be found in user-set metadata of varying specificity or the global
 * configuration.  Returns nil if no context can be found.
 *
 * @param report A dictionary of report data
 * @returns A string context if found, or nil
 */
NSString *BSGParseContext(NSDictionary *report) {
    id context = [report valueForKeyPath:@"user.overrides.context"];
    if ([context isKindOfClass:[NSString class]]) {
        return context;
    }
    context = BSGLoadConfigValue(report, BSGKeyContext);
    if ([context isKindOfClass:[NSString class]]) {
        return context;
    }
    return nil;
}

NSString *BSGParseGroupingHash(NSDictionary *report) {
    id groupingHash = [report valueForKeyPath:@"user.overrides.groupingHash"];
    if (groupingHash)
        return groupingHash;
    return nil;
}

/** 
 * Find the breadcrumb cache for the event within the report object.
 *
 * By default, crumbs are present in the `user.state.crash` object, which is
 * the location of user data within crash and notify reports. However, this
 * location can be overridden in the case that a callback modifies breadcrumbs
 * or that breadcrumbs are persisted separately (such as in an out-of-memory
 * event).
 */
NSArray <BugsnagBreadcrumb *> *BSGParseBreadcrumbs(NSDictionary *report) {
    // default to overwritten breadcrumbs from callback
    NSArray *cache = [report valueForKeyPath:@"user.overrides.breadcrumbs"]
        // then cached breadcrumbs from an OOM event
        ?: [report valueForKeyPath:@"user.state.oom.breadcrumbs"]
        // then cached breadcrumbs from a regular event
        // KSCrashReports from earlier versions of the notifier used this
        ?: [report valueForKeyPath:@"user.state.crash.breadcrumbs"]
        // breadcrumbs added to a KSCrashReport by BSSerializeDataCrashHandler
        ?: [report valueForKeyPath:@"user.breadcrumbs"];
    NSMutableArray *breadcrumbs = [NSMutableArray arrayWithCapacity:cache.count];
    for (NSDictionary *data in cache) {
        if (![data isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        BugsnagBreadcrumb *crumb = [BugsnagBreadcrumb breadcrumbFromDict:data];
        if (crumb) {
            [breadcrumbs addObject:crumb];
        }
    }
    return breadcrumbs;
}

BSGMemoryFeatureFlagStore *BSGParseFeatureFlags(NSDictionary *report) {
    // default to overwritten featureFlags from callback
    NSArray *cache = [report valueForKeyPath:@"user.overrides.featureFlags"]
        // then cached featureFlags from an OOM event
        ?: [report valueForKeyPath:@"user.state.oom.featureFlags"]
        // then cached featureFlags from a regular event
        // KSCrashReports from earlier versions of the notifier used this
        ?: [report valueForKeyPath:@"user.state.crash.featureFlags"]
        // featureFlags added to a KSCrashReport by BSSerializeDataCrashHandler
        ?: [report valueForKeyPath:@"user.featureFlags"];
    
    return BSGFeatureFlagStoreFromJSON(cache);
}

NSString *BSGParseReleaseStage(NSDictionary *report) {
    return [report valueForKeyPath:@"user.overrides.releaseStage"]
               ?: BSGLoadConfigValue(report, @"releaseStage");
}

NSDictionary *BSGParseCustomException(NSDictionary *report,
                                      NSString *errorClass, NSString *message) {
    id frames =
        [report valueForKeyPath:@"user.overrides.customStacktraceFrames"];
    id type = [report valueForKeyPath:@"user.overrides.customStacktraceType"];
    if (type && frames) {
        return @{
            BSGKeyStacktrace : frames,
            BSGKeyType : type,
            BSGKeyErrorClass : errorClass,
            BSGKeyMessage : message
        };
    }

    return nil;
}

// MARK: -

BSG_OBJC_DIRECT_MEMBERS
@implementation BugsnagEvent

/**
 * Constructs a new instance of BugsnagEvent. This is the preferred constructor
 * and initialises all the mandatory fields. All internal constructors should
 * chain this constructor to ensure a consistent state. This constructor should
 * only assign parameters to fields, and should avoid any complex business logic.
 *
 * @param app the state of the app at the time of the error
 * @param device the state of the app at the time of the error
 * @param handledState whether the error was handled/unhandled, plus additional severity info
 * @param user the user at the time of the error
 * @param metadata the metadata at the time of the error
 * @param breadcrumbs the breadcrumbs at the time of the error
 * @param errors an array of errors representing a causal relationship
 * @param threads the threads at the time of the error, or empty if none
 * @param session the active session or nil if
 * @return a new instance of BugsnagEvent.
 */
- (instancetype)initWithApp:(BugsnagAppWithState *)app
                     device:(BugsnagDeviceWithState *)device
               handledState:(BugsnagHandledState *)handledState
                       user:(BugsnagUser *)user
                   metadata:(BugsnagMetadata *)metadata
                breadcrumbs:(NSArray<BugsnagBreadcrumb *> *)breadcrumbs
                     errors:(NSArray<BugsnagError *> *)errors
                    threads:(NSArray<BugsnagThread *> *)threads
                    session:(BugsnagSession *)session {
    if ((self = [super init])) {
        _app = app;
        _device = device;
        _handledState = handledState;
        // _user is nonnull but this method is not public so _Nonnull is unenforcable,  Guard explicitly.
        if (user != nil) {
            _user = user;
        }
        _metadata = metadata;
        _breadcrumbs = breadcrumbs;
        _errors = errors;
        _featureFlagStore = [[BSGMemoryFeatureFlagStore alloc] init];
        _threads = threads;
        _session = [session copy];
    }
    return self;
}

- (instancetype)initWithJson:(NSDictionary *)json {
    if ((self = [super init])) {
        _apiKey = BSGDeserializeString(json[BSGKeyApiKey]);

        _app = BSGDeserializeObject(json[BSGKeyApp], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [BugsnagAppWithState appFromJson:dict];
        }) ?: [[BugsnagAppWithState alloc] init];

        _breadcrumbs = BSGDeserializeArrayOfObjects(json[BSGKeyBreadcrumbs], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [BugsnagBreadcrumb breadcrumbFromDict:dict];
        }) ?: @[];

        _context = BSGDeserializeString(json[BSGKeyContext]);

        _correlation = [[BugsnagCorrelation alloc] initWithJsonDictionary:json[BSGKeyCorrelation]];

        _device = BSGDeserializeObject(json[BSGKeyDevice], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [BugsnagDeviceWithState deviceFromJson:dict];
        }) ?: [[BugsnagDeviceWithState alloc] init];

        _errors = BSGDeserializeArrayOfObjects(json[BSGKeyExceptions], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [BugsnagError errorFromJson:dict];
        }) ?: @[];

        _featureFlagStore = BSGFeatureFlagStoreFromJSON(json[BSGKeyFeatureFlags]);

        _groupingHash = BSGDeserializeString(json[BSGKeyGroupingHash]);

        _handledState = [BugsnagHandledState handledStateFromJson:json];

        _metadata = BSGDeserializeObject(json[BSGKeyMetadata], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [[BugsnagMetadata alloc] initWithDictionary:dict];
        }) ?: [[BugsnagMetadata alloc] init];

        _threads = BSGDeserializeArrayOfObjects(json[BSGKeyThreads], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [BugsnagThread threadFromJson:dict];
        }) ?: @[];

        _usage = BSGDeserializeDict(json[BSGKeyUsage]);

        _user = BSGDeserializeObject(json[BSGKeyUser], ^id _Nullable(NSDictionary * _Nonnull dict) {
            return [[BugsnagUser alloc] initWithDictionary:dict];
        }) ?: [[BugsnagUser alloc] init];

        _session = BSGSessionFromEventJson(json[BSGKeySession], _app, _device, _user);
    }
    return self;
}

/**
 * Creates a BugsnagEvent from a JSON crash report generated by KSCrash. A KSCrash
 * report can come in 3 variants, which needs to be deserialized separately:
 *
 * 1. An unhandled error which immediately terminated the process
 * 2. A handled error which did not terminate the process
 * 3. An OOM, which has more limited information than the previous two errors
 *
 *  @param event a KSCrash report
 *
 *  @return a BugsnagEvent containing the parsed information
 */
- (instancetype)initWithKSReport:(NSDictionary *)event {
    if (event.count == 0) {
        return nil; // report is empty
    }
    if ([[event valueForKeyPath:@"user.state.didOOM"] boolValue]) {
        return nil; // OOMs are no longer stored as KSCrashReports
    } else if ([event valueForKeyPath:@"user.event"] != nil) {
        return [self initWithUserData:event];
    } else {
        return [self initWithKSCrashReport:event];
    }
}

/**
 * Creates a BugsnagEvent from unhandled error JSON. Unhandled errors use
 * the JSON schema supplied by the KSCrash report rather than the Bugsnag
 * Error API schema, which is more complex to parse.
 *
 * @param event a KSCrash report
 *
 * @return a BugsnagEvent containing the parsed information
 */
- (instancetype)initWithKSCrashReport:(NSDictionary *)event {
    NSMutableDictionary *error = [[event valueForKeyPath:@"crash.error"] mutableCopy];
    NSString *errorType = error[BSGKeyType];

    // Always assume that a report coming from KSCrash is by default an unhandled error.
    BOOL isUnhandled = YES;
    BOOL isUnhandledOverridden = NO;
    BOOL hasBecomeHandled = [event valueForKeyPath:@"user.unhandled"] != nil &&
            [[event valueForKeyPath:@"user.unhandled"] boolValue] == false;
    if (hasBecomeHandled) {
        const int handledCountAdjust = 1;
        isUnhandled = NO;
        isUnhandledOverridden = YES;
        NSMutableDictionary *user = [event[BSGKeyUser] mutableCopy];
        user[@"unhandled"] = @(isUnhandled);
        user[@"unhandledOverridden"] = @(isUnhandledOverridden);
        user[@"unhandledCount"] = @([user[@"unhandledCount"] intValue] - handledCountAdjust);
        user[@"handledCount"] = @([user[@"handledCount"] intValue] + handledCountAdjust);
        NSMutableDictionary *eventCopy = [event mutableCopy];
        eventCopy[BSGKeyUser] = user;
        event = eventCopy;
    }

    id userMetadata = [event valueForKeyPath:@"user.metaData"];
    BugsnagMetadata *metadata;

    if ([userMetadata isKindOfClass:[NSDictionary class]]) {
        metadata = [[BugsnagMetadata alloc] initWithDictionary:userMetadata];
    } else {
        metadata = [BugsnagMetadata new];
    }

    [metadata addMetadata:error toSection:BSGKeyError];

    // Device information that isn't part of `event.device`
    NSMutableDictionary *deviceMetadata = BSGParseDeviceMetadata(event);
#if BSG_HAVE_BATTERY
    deviceMetadata[BSGKeyBatteryLevel] = [event valueForKeyPath:@"user.batteryLevel"];
    deviceMetadata[BSGKeyCharging] = [event valueForKeyPath:@"user.charging"];
#endif
    if (@available(iOS 11.0, tvOS 11.0, watchOS 4.0, *)) {
        NSNumber *thermalState = [event valueForKeyPath:@"user.thermalState"];
        if ([thermalState isKindOfClass:[NSNumber class]]) {
            deviceMetadata[BSGKeyThermalState] = BSGStringFromThermalState(thermalState.longValue);
        }
    }
    [metadata addMetadata:deviceMetadata toSection:BSGKeyDevice];

    [metadata addMetadata:BSGParseAppMetadata(event) toSection:BSGKeyApp];

    NSDictionary *recordedState = [event valueForKeyPath:@"user.handledState"];

    NSUInteger depth;
    if (recordedState) { // only makes sense to use serialised value for handled exceptions
        depth = [[event valueForKeyPath:@"user.depth"] unsignedIntegerValue];
    } else {
        depth = 0;
    }

    // generate threads/error info
    NSArray *binaryImages = event[@"binary_images"];
    NSArray *threadDict = [event valueForKeyPath:@"crash.threads"];
    NSArray<BugsnagThread *> *threads = [BugsnagThread threadsFromArray:threadDict binaryImages:binaryImages];

    BugsnagThread *errorReportingThread = nil;
    for (BugsnagThread *thread in threads) {
        if (thread.errorReportingThread) {
            errorReportingThread = thread;
            break;
        }
    }

    NSArray<BugsnagError *> *errors = @[[[BugsnagError alloc] initWithKSCrashReport:event stacktrace:errorReportingThread.stacktrace ?: @[]]];

    // KSCrash captures only the offending thread when sendThreads = BSGThreadSendPolicyNever.
    // The BugsnagEvent should not contain threads in this case, only the stacktrace.
    if (threads.count == 1) {
        threads = @[];
    }

    if (errorReportingThread.crashInfoMessage) {
        [errors[0] updateWithCrashInfoMessage:(NSString * _Nonnull)errorReportingThread.crashInfoMessage];
        [metadata addMetadata:errorReportingThread.crashInfoMessage withKey:@"crashInfo" toSection:@"error"];
    }
    
    BugsnagHandledState *handledState;
    if (recordedState) {
        handledState = [[BugsnagHandledState alloc] initWithDictionary:recordedState];
    } else { // the event was (probably) unhandled.
        BOOL isSignal = [BSGKeySignal isEqualToString:errorType];
        SeverityReasonType severityReason = isSignal ? Signal : UnhandledException;
        handledState = [BugsnagHandledState
                handledStateWithSeverityReason:severityReason
                                      severity:BSGSeverityError
                                     attrValue:errors[0].errorClass];
        handledState.unhandled = isUnhandled;
        handledState.unhandledOverridden = isUnhandledOverridden;
    }

    [[self parseOnCrashData:event] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] &&
            [obj isKindOfClass:[NSDictionary class]]) {
            [metadata addMetadata:obj toSection:key];
        }
    }];

    NSString *deviceAppHash = [event valueForKeyPath:@"system.device_app_hash"];
    BugsnagDeviceWithState *device = [BugsnagDeviceWithState deviceWithKSCrashReport:event];
#if TARGET_OS_IOS
    NSNumber *orientation = [event valueForKeyPath:@"user.orientation"];
    if ([orientation isKindOfClass:[NSNumber class]]) {
        device.orientation = BSGStringFromDeviceOrientation(orientation.longValue);
    }
#endif

    BugsnagUser *user = [self parseUser:event deviceAppHash:deviceAppHash deviceId:device.id];

    NSDictionary *configDict = [event valueForKeyPath:@"user.config"];
    BugsnagConfiguration *config = [[BugsnagConfiguration alloc] initWithDictionaryRepresentation:
                                    [configDict isKindOfClass:[NSDictionary class]] ? configDict : @{}];

    NSDictionary *correlationDict = [event valueForKeyPath:@"user.correlation"];
    NSString *traceId = correlationDict[@"traceId"];
    NSString *spanId = correlationDict[@"spanId"];

    BugsnagAppWithState *app = [BugsnagAppWithState appWithDictionary:event config:config codeBundleId:self.codeBundleId];

    BugsnagSession *session = BSGSessionFromCrashReport(event, app, device, user);

    BugsnagEvent *obj = [self initWithApp:app
                                   device:device
                             handledState:handledState
                                     user:user
                                 metadata:metadata
                              breadcrumbs:BSGParseBreadcrumbs(event)
                                   errors:errors
                                  threads:threads
                                  session:session];
    obj.context = BSGParseContext(event);
    obj.groupingHash = BSGParseGroupingHash(event);
    obj.enabledReleaseStages = BSGLoadConfigValue(event, BSGKeyEnabledReleaseStages);
    obj.releaseStage = BSGParseReleaseStage(event);
    obj.deviceAppHash = deviceAppHash;
    obj.featureFlagStore = BSGParseFeatureFlags(event);
    obj.context = [event valueForKeyPath:@"user.state.client.context"];
    obj.customException = BSGParseCustomException(event, [errors[0].errorClass copy], [errors[0].errorMessage copy]);
    obj.depth = depth;
    obj.usage = [event valueForKeyPath:@"user._usage"];

    if (traceId.length > 0 || spanId.length > 0) {
        obj.correlation = [[BugsnagCorrelation alloc] initWithTraceId:traceId spanId:spanId];
    }

    return obj;
}

/**
 * Creates a BugsnagEvent from handled error JSON. Handled errors use
 * the Bugsnag Error API JSON schema, with the exception that they are
 * wrapped in a KSCrash JSON object.
 *
 * @param crashReport a KSCrash report
 *
 * @return a BugsnagEvent containing the parsed information
 */
- (instancetype)initWithUserData:(NSDictionary *)crashReport {
    NSDictionary *json = BSGDeserializeDict([crashReport valueForKeyPath:@"user.event"]);
    if (!json || !(self = [self initWithJson:json])) {
        return nil;
    }
    _apiKey = BSGDeserializeString(json[BSGKeyApiKey]);
    _context = BSGDeserializeString(json[BSGKeyContext]);
    _featureFlagStore = [[BSGMemoryFeatureFlagStore alloc] init];
    _groupingHash = BSGDeserializeString(json[BSGKeyGroupingHash]);

    if (_errors.count) {
        BugsnagError *error = _errors[0];
        _customException = BSGParseCustomException(crashReport, error.errorClass, error.errorMessage);
    }
    return self;
}

- (NSMutableDictionary *)parseOnCrashData:(NSDictionary *)report {
    NSMutableDictionary *userAtCrash = [report[BSGKeyUser] mutableCopy];
    // avoid adding internal information to user-defined metadata
    NSArray *keysToRemove = @[
            @BSG_KSCrashField_Overrides,
            @BSG_KSCrashField_HandledState,
            @BSG_KSCrashField_Metadata,
            @BSG_KSCrashField_State,
            @BSG_KSCrashField_Config,
            @BSG_KSCrashField_DiscardDepth,
            @"batteryLevel",
            @"breadcrumbs",
            @"charging",
            @"handledCount",
            @"id",
            @"isLaunching",
            @"orientation",
            @"startedAt",
            @"thermalState",
            @"unhandledCount",
    ];
    [userAtCrash removeObjectsForKeys:keysToRemove];

    for (NSString *key in [userAtCrash allKeys]) {
        if ([key hasPrefix:@"_"]) {
            [userAtCrash removeObjectForKey:key];
            continue;
        }
        if (![userAtCrash[key] isKindOfClass:[NSDictionary class]]) {
            bsg_log_debug(@"Removing value added in onCrashHandler for key %@ as it is not a dictionary value", key);
            [userAtCrash removeObjectForKey:key];
        }
    }
    return userAtCrash;
}

// MARK: - apiKey

@synthesize apiKey = _apiKey;

- (NSString *)apiKey {
    return _apiKey;
}

- (void)setApiKey:(NSString *)apiKey {
    if ([BugsnagConfiguration isValidApiKey:apiKey]) {
        _apiKey = apiKey;
    }

    // A malformed apiKey should not cause an error: the fallback global value
    // in BugsnagConfiguration will do to get the event reported.
    else {
        bsg_log_warn(@"Attempted to set an invalid Event API key.");
    }
}

- (BOOL)shouldBeSent {
    return [self.enabledReleaseStages containsObject:self.releaseStage ?: @""] ||
           (self.enabledReleaseStages.count == 0);
}

- (NSArray<NSDictionary *> *)serializeBreadcrumbsWithRedactedKeys:(NSSet *)redactedKeys {
    return BSGArrayMap(self.breadcrumbs, ^NSDictionary * (BugsnagBreadcrumb *breadcrumb) {
        NSMutableDictionary *dictionary = [[breadcrumb objectValue] mutableCopy];
        NSDictionary *metadata = dictionary[BSGKeyMetadata];
        NSMutableDictionary *redactedMetadata = [NSMutableDictionary dictionary];
        for (NSString *key in metadata) {
            redactedMetadata[key] = [self redactedMetadataValue:metadata[key] forKey:key redactedKeys:redactedKeys];
        }
        dictionary[BSGKeyMetadata] = redactedMetadata;
        return dictionary;
    });
}

- (void)attachCustomStacktrace:(NSArray *)frames withType:(NSString *)type {
    BugsnagError *error = self.errors.firstObject;
    error.stacktrace = [BugsnagStacktrace stacktraceFromJson:frames].trace;
    error.typeString = type;
}

- (BSGSeverity)severity {
    return self.handledState.currentSeverity;
}

- (void)setSeverity:(BSGSeverity)severity {
    self.handledState.currentSeverity = severity;
}

// =============================================================================
// MARK: - User
// =============================================================================

/**
 *  Set user metadata
 *
 *  @param userId ID of the user
 *  @param name   Name of the user
 *  @param email  Email address of the user
 */
- (void)setUser:(NSString *_Nullable)userId
      withEmail:(NSString *_Nullable)email
        andName:(NSString *_Nullable)name {
    self.user = [[BugsnagUser alloc] initWithId:userId name:name emailAddress:email];
}

- (void) setCorrelationTraceId:(NSString *_Nonnull)traceId spanId:(NSString *_Nonnull)spanId {
    self.correlation = [[BugsnagCorrelation alloc] initWithTraceId:traceId spanId:spanId];
}

/**
 * Read the user from a persisted KSCrash report
 * @param event the KSCrash report
 * @return the user, or nil if not available
 */
- (BugsnagUser *)parseUser:(NSDictionary *)event
             deviceAppHash:(NSString *)deviceAppHash
                  deviceId:(NSString *)deviceId {
    NSMutableDictionary *user = [[event valueForKeyPath:@"user.state"][BSGKeyUser] mutableCopy];
    
    if (user == nil) { // fallback to legacy location
        user = [[event valueForKeyPath:@"user.metaData"][BSGKeyUser] mutableCopy];
    }
    if (user == nil) { // fallback to empty dict
        user = [NSMutableDictionary new];
    }

    if (!user[BSGKeyId] && deviceId) { // if device id is null, don't set user id to default
        user[BSGKeyId] = deviceAppHash;
    }
    return [[BugsnagUser alloc] initWithDictionary:user];
}

- (void)notifyUnhandledOverridden {
    self.handledState.unhandledOverridden = YES;
}

- (NSDictionary *)toJsonWithRedactedKeys:(NSSet *)redactedKeys {
    NSMutableDictionary *event = [NSMutableDictionary dictionary];

    event[BSGKeyExceptions] = ({
        NSMutableArray *array = [NSMutableArray array];
        [self.errors enumerateObjectsUsingBlock:^(BugsnagError *error, NSUInteger idx, __unused BOOL *stop) {
            if (self.customException != nil && idx == 0) {
                [array addObject:(NSDictionary * _Nonnull)self.customException];
            } else {
                [array addObject:[error toDictionary]];
            }
        }];
        [NSArray arrayWithArray:array];
    });
    
    event[BSGKeyThreads] = [BugsnagThread serializeThreads:self.threads];
    event[BSGKeySeverity] = BSGFormatSeverity(self.severity);
    event[BSGKeyBreadcrumbs] = [self serializeBreadcrumbsWithRedactedKeys:redactedKeys];

    NSMutableDictionary *metadata = [[[self metadata] toDictionary] mutableCopy];
    @try {
        [self redactKeys:redactedKeys inMetadata:metadata];
        event[BSGKeyMetadata] = metadata;
    } @catch (NSException *exception) {
        bsg_log_err(@"An exception was thrown while sanitising metadata: %@", exception);
    }

    event[BSGKeyApiKey] = self.apiKey;
    event[BSGKeyDevice] = [self.device toDictionary];
    event[BSGKeyApp] = [self.app toDict];

    event[BSGKeyContext] = [self context];
    event[BSGKeyCorrelation] = [self.correlation toJsonDictionary];
    event[BSGKeyFeatureFlags] = BSGFeatureFlagStoreToJSON(self.featureFlagStore);
    event[BSGKeyGroupingHash] = self.groupingHash;

    event[BSGKeyUnhandled] = @(self.handledState.unhandled);

    // serialize handled/unhandled into payload
    NSMutableDictionary *severityReason = [NSMutableDictionary new];
    if (self.handledState.unhandledOverridden) {
        severityReason[BSGKeyUnhandledOverridden] = @(self.handledState.unhandledOverridden);
    }
    NSString *reasonType = [BugsnagHandledState
        stringFromSeverityReason:self.handledState.calculateSeverityReasonType];
    severityReason[BSGKeyType] = reasonType;

    if (self.handledState.attrKey && self.handledState.attrValue) {
        severityReason[BSGKeyAttributes] =
            @{self.handledState.attrKey : self.handledState.attrValue};
    }

    event[BSGKeySeverityReason] = severityReason;

    //  Inserted into `context` property
    [metadata removeObjectForKey:BSGKeyContext];

    // add user
    event[BSGKeyUser] = [self.user toJson];

    event[BSGKeySession] = self.session ? BSGSessionToEventJson((BugsnagSession *_Nonnull)self.session) : nil;

    event[BSGKeyUsage] = self.usage;

    return event;
}

- (void)redactKeys:(NSSet *)redactedKeys inMetadata:(NSMutableDictionary *)metadata {
    for (NSString *sectionKey in [metadata allKeys]) {
        if ([metadata[sectionKey] isKindOfClass:[NSDictionary class]]) {
            metadata[sectionKey] = [metadata[sectionKey] mutableCopy];
        } else {
            NSString *message = [NSString stringWithFormat:@"Expected an NSDictionary but got %@ %@",
                                 NSStringFromClass([(id _Nonnull)metadata[sectionKey] class]), metadata[sectionKey]];
            bsg_log_err(@"%@", message);
            // Leave an indication of the error in the payload for diagnosis
            metadata[sectionKey] = [@{@"bugsnag.error": message} mutableCopy];
        }
        NSMutableDictionary *section = metadata[sectionKey];

        if (section != nil) { // redact sensitive metadata values
            for (NSString *objKey in [section allKeys]) {
                section[objKey] = [self redactedMetadataValue:section[objKey] forKey:objKey redactedKeys:redactedKeys];
            }
        }
    }
}

- (id)redactedMetadataValue:(id)value forKey:(NSString *)key redactedKeys:(NSSet *)redactedKeys {
    if ([self redactedKeys:redactedKeys matches:key]) {
        return RedactedMetadataValue;
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *nestedDict = [(NSDictionary *)value mutableCopy];
        for (NSString *nestedKey in [nestedDict allKeys]) {
            nestedDict[nestedKey] = [self redactedMetadataValue:nestedDict[nestedKey] forKey:nestedKey redactedKeys:redactedKeys];
        }
        return nestedDict;
    } else {
        return value;
    }
}

- (BOOL)redactedKeys:(NSSet *)redactedKeys matches:(NSString *)key {
    for (id obj in redactedKeys) {
        if ([obj isKindOfClass:[NSString class]]) {
            if ([[key lowercaseString] isEqualToString:[obj lowercaseString]]) {
                return true;
            }
        } else if ([obj isKindOfClass:[NSRegularExpression class]]) {
            NSRegularExpression *regex = obj;
            NSRange range = NSMakeRange(0, [key length]);
            if ([[regex matchesInString:key options:0 range:range] count] > 0) {
                return true;
            }
        }
    }
    return false;
}

- (void)symbolicateIfNeeded {
    for (BugsnagError *error in self.errors) {
        for (BugsnagStackframe *stackframe in error.stacktrace) {
            [stackframe symbolicateIfNeeded];
        }
    }
    for (BugsnagThread *thread in self.threads) {
        for (BugsnagStackframe *stackframe in thread.stacktrace) {
            [stackframe symbolicateIfNeeded];
        }
    }
}

- (void)trimBreadcrumbs:(const NSUInteger)bytesToRemove {
    NSMutableArray *breadcrumbs = [self.breadcrumbs mutableCopy];
    BugsnagBreadcrumb *lastRemovedBreadcrumb = nil;
    NSUInteger bytesRemoved = 0, count = 0;
    
    while (bytesRemoved < bytesToRemove && breadcrumbs.count) {
        lastRemovedBreadcrumb = [breadcrumbs firstObject];
        [breadcrumbs removeObjectAtIndex:0];
        
        NSDictionary *dict = [lastRemovedBreadcrumb objectValue];
        NSData *data = BSGJSONDataFromDictionary(dict, NULL);
        bytesRemoved += data.length;
        count++;
    }
    
    if (lastRemovedBreadcrumb) {
        lastRemovedBreadcrumb.message = count < 2 ? @"Removed to reduce payload size" :
        [NSString stringWithFormat:@"Removed, along with %lu older breadcrumb%s, to reduce payload size",
         (unsigned long)(count - 1), count == 2 ? "" : "s"];
        lastRemovedBreadcrumb.metadata = @{};
        [breadcrumbs insertObject:lastRemovedBreadcrumb atIndex:0];
    }
    
    self.breadcrumbs = breadcrumbs;
    
    NSDictionary *usage = self.usage;
    if (usage) {
        self.usage = BSGDictMerge(@{
            @"system": @{
                @"breadcrumbBytesRemoved": @(bytesRemoved),
                @"breadcrumbsRemoved": @(count)}
        }, usage);
    }
}

- (void)truncateStrings:(NSUInteger)maxLength {
    BSGTruncateContext context = {
        .maxLength = maxLength
    };
    
    if (self.context) {
        self.context = BSGTruncatePossibleString(&context, self.context);
    }
    
    for (BugsnagError *error in self.errors) {
        error.errorClass = BSGTruncatePossibleString(&context, error.errorClass);
        error.errorMessage = BSGTruncatePossibleString(&context, error.errorMessage);
    }
    
    for (BugsnagBreadcrumb *breadcrumb in self.breadcrumbs) {
        breadcrumb.message = BSGTruncateString(&context, breadcrumb.message);
        breadcrumb.metadata = BSGTruncateStrings(&context, breadcrumb.metadata);
    }
    
    BugsnagMetadata *metadata = self.metadata; 
    if (metadata) {
        self.metadata = [[BugsnagMetadata alloc] initWithDictionary:
                         BSGTruncateStrings(&context, metadata.dictionary)];
    }
    
    NSDictionary *usage = self.usage;
    if (usage) {
        self.usage = BSGDictMerge(@{
            @"system": @{
                @"stringCharsTruncated": @(context.length),
                @"stringsTruncated": @(context.strings)}
        }, usage);
    }
}

- (BOOL)unhandled {
    return self.handledState.unhandled;
}

- (void)setUnhandled:(BOOL)unhandled {
    self.handledState.unhandled = unhandled;
}

// MARK: - <BugsnagFeatureFlagStore>

- (NSArray<BugsnagFeatureFlag *> *)featureFlags {
    return self.featureFlagStore.allFlags;
}

- (void)addFeatureFlagWithName:(NSString *)name variant:(nullable NSString *)variant {
    [self.featureFlagStore addFeatureFlag:name withVariant:variant];
}

- (void)addFeatureFlagWithName:(NSString *)name {
    [self.featureFlagStore addFeatureFlag:name withVariant:nil];
}

- (void)addFeatureFlags:(NSArray<BugsnagFeatureFlag *> *)featureFlags {
    [self.featureFlagStore addFeatureFlags:featureFlags];
}

- (void)clearFeatureFlagWithName:(NSString *)name {
    [self.featureFlagStore clear:name];
}

- (void)clearFeatureFlags {
    [self.featureFlagStore clear];
}

// MARK: - <BugsnagMetadataStore>

- (void)addMetadata:(NSDictionary *_Nonnull)metadata
          toSection:(NSString *_Nonnull)sectionName
{
    [self.metadata addMetadata:metadata toSection:sectionName];
}

- (void)addMetadata:(id _Nullable)metadata
            withKey:(NSString *_Nonnull)key
          toSection:(NSString *_Nonnull)sectionName
{
    [self.metadata addMetadata:metadata withKey:key toSection:sectionName];
}

- (id _Nullable)getMetadataFromSection:(NSString *_Nonnull)sectionName
                               withKey:(NSString *_Nonnull)key
{
    return [self.metadata getMetadataFromSection:sectionName withKey:key];
}

- (NSMutableDictionary *_Nullable)getMetadataFromSection:(NSString *_Nonnull)sectionName
{
    return [self.metadata getMetadataFromSection:sectionName];
}

- (void)clearMetadataFromSection:(NSString *_Nonnull)sectionName
{
    [self.metadata clearMetadataFromSection:sectionName];
}

- (void)clearMetadataFromSection:(NSString *_Nonnull)sectionName
                       withKey:(NSString *_Nonnull)key
{
    [self.metadata clearMetadataFromSection:sectionName withKey:key];
}

#pragma mark -

- (NSArray<NSString *> *)stacktraceTypes {
    NSMutableSet *stacktraceTypes = [NSMutableSet set];
    
    // The error in self.errors is not always the error that will be sent; this is the case when used in React Native.
    // Using [self toJson] to ensure this uses the same logic of reading from self.customException instead.
    NSDictionary *json = [self toJsonWithRedactedKeys:nil];
    NSArray *exceptions = json[BSGKeyExceptions];
    for (NSDictionary *exception in exceptions) {
        BugsnagError *error = [BugsnagError errorFromJson:exception];
        
        [stacktraceTypes addObject:BSGSerializeErrorType(error.type)];
        
        for (BugsnagStackframe *stackframe in error.stacktrace) {
            BSGSetAddIfNonnull(stacktraceTypes, stackframe.type);
        }
    }
    
    for (BugsnagThread *thread in self.threads) {
        [stacktraceTypes addObject:BSGSerializeThreadType(thread.type)];
        for (BugsnagStackframe *stackframe in thread.stacktrace) {
            BSGSetAddIfNonnull(stacktraceTypes, stackframe.type);
        }
    }
    
    return stacktraceTypes.allObjects;
}

@end
