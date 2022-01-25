//
//  EnabledBreadcrumbTypesIsNilScenario.swift
//  iOSTestApp
//
//  Created by Robin Macharg on 25/03/2020.
//  Copyright © 2020 Bugsnag. All rights reserved.
//

import Foundation

class EnabledBreadcrumbTypesIsNilScenario : Scenario {
    override func startBugsnag() {
        config.autoTrackSessions = false;
        config.enabledBreadcrumbTypes = [];
        super.startBugsnag()
    }
 
    override func run() {
        Bugsnag.leaveBreadcrumb("Should not see this navigation", metadata: nil, type: .navigation)
        Bugsnag.leaveBreadcrumb("Should not see this request", metadata: nil, type: .request)

        Bugsnag.notifyError(MagicError(domain: "com.example",
                                       code: 43,
                                       userInfo: [NSLocalizedDescriptionKey: "incoming!"]))
    }
}
