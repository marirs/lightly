import XCTest

/// Keeps device UI tests from answering system alerts on the owner's phones.
///
/// Without a monitor, XCTest's default interruption handler taps an alert's default button. On 2026-11-05 that
/// answered "Yes" to iOS's "Add <number> for iMessage and FaceTime?" on the iPhone SE 3, an account change the
/// owner had to undo. This monitor only ever declines: it taps the first decline button it finds and never a
/// default or confirming one. An alert with no decline button is left untouched and the test stops, so a person
/// can answer it.
enum SystemAlertGuard {
    /// Labels that decline or postpone without changing anything. Compared exactly, never by prefix.
    static let declineLabels = ["No", "Not Now", "Cancel", "Don't Allow", "Don’t Allow", "Later", "Close", "Dismiss"]

    static func install(on testCase: XCTestCase) {
        testCase.addUIInterruptionMonitor(withDescription: "Decline system alerts, never accept") { alert in
            for label in declineLabels {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            // Returning true stops the default handler, which would tap the default (often accepting) button.
            testCase.continueAfterFailure = false
            XCTFail("System alert with no decline button left for a person to answer: \(alert.label)")
            return true
        }
    }
}
