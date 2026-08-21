import Foundation
import UserNotifications
import UIKit

/// Posts a local "scan complete" notification so a long sweep can be left
/// running instead of watched.
///
/// Permission is asked for at the moment the first scan starts rather than at
/// launch, so the prompt arrives when the reason for it is obvious.
enum ScanNotifier {
    private static let identifier = "scan-complete"

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyScanComplete(flagged: Int, scanned: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Scan complete"
        content.body = flagged == 0
            ? "Nothing to clean — \(scanned.formatted()) photos all looked fine."
            : "\(flagged.formatted()) of \(scanned.formatted()) photos look like junk. Tap to review."
        content.sound = .default

        // nil trigger delivers immediately; iOS suppresses the banner on its own
        // when the app is already in front, which is the behaviour we want.
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        try? await center.add(request)
    }
}

/// Keeps the app running a little longer when it is backgrounded mid-scan.
///
/// iOS only grants a short extension, so a large library will still be
/// suspended before it finishes — this buys the tail end of a scan, not an
/// unattended one.
@MainActor
final class BackgroundScanAssertion {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "SnapSweep scan") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
