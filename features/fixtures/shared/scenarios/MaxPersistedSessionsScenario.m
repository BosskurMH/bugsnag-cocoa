//
//  MaxPersistedSessionsScenario.m
//  macOSTestApp
//
//  Created by Nick Dowell on 13/05/2022.
//  Copyright © 2022 Bugsnag Inc. All rights reserved.
//

#import "Scenario.h"
#import "Logging.h"

@interface MaxPersistedSessionsScenario : Scenario
@end

@implementation MaxPersistedSessionsScenario

- (void)startBugsnag {
    self.config.autoTrackSessions = NO;
    self.config.maxPersistedSessions = 1;

    [super startBugsnag];

    [self performBlockAndWaitForSessionDelivery:^{
        [Bugsnag setUser:[self nextUserId] withEmail:nil andName:nil];
        [Bugsnag startSession];
    }];
}

- (void)run {
    // Filesystem timestamps have a resolution of 1 second, so wait to ensure
    // that the first persisted session will have an older file creation date.
    [NSThread sleepForTimeInterval:1];

    [Bugsnag setUser:[self nextUserId] withEmail:nil andName:nil];
    [Bugsnag startSession];
}

- (NSString *)nextUserId {
    NSString *key = @"sessionCounter";
    NSInteger sessionCounter = [NSUserDefaults.standardUserDefaults integerForKey:key] + 1;
    [NSUserDefaults.standardUserDefaults setInteger:sessionCounter forKey:key];
    return [NSString stringWithFormat:@"%ld", (long) sessionCounter];
}

@end
