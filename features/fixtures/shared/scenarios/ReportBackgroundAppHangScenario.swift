import UIKit

class ReportBackgroundAppHangScenario: Scenario {

    override func startBugsnag() {
        self.config.appHangThresholdMillis = 1_000
        self.config.reportBackgroundAppHangs = true
        self.config.addOnSendError { event in
            !event.errors[0].stacktrace.contains { stackframe in
                // CABackingStoreCollectBlocking is known to hang for several seconds upon entering the background
                stackframe.method == "CABackingStoreCollectBlocking"
            }
        }
        super.startBugsnag()
    }

    override func run() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            let backgroundTask = UIApplication.shared.beginBackgroundTask()
            
            let timeInterval: TimeInterval = 2
            NSLog("Simulating an app hang of \(timeInterval) seconds...")
            Thread.sleep(forTimeInterval: timeInterval)
            NSLog("Finished sleeping")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }
}
