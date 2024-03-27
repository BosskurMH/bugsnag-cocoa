class OldHandledErrorScenario: Scenario {
    
    override func configure() {
        super.configure()
        modifyEventCreationDate()
        config.autoTrackSessions = false
        config.enabledErrorTypes.ooms = false
    }
    
    override func run() {
        Bugsnag.notifyError(NSError(domain: "", code: 0, userInfo: nil))
    }
    
    func modifyEventCreationDate() {
        let dir = [NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0],
                   "com.bugsnag.Bugsnag",
                   Bundle.main.bundleIdentifier!,
                   "v1",
                   "events"].joined(separator: "/")
        
        let creationDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -61, to: Date())!
        
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
                let file = (dir as NSString).appendingPathComponent(name)
                try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: file)
                logDebug("OldCrashReportScenario: Updated creation date of \((file as NSString).lastPathComponent) to \(creationDate)")
            }
        } catch {
            logError("\(error)")
        }
    }
}
