import UIKit

/// Keeps the phone from auto-locking only while long foreground work runs (2026-10-07): subject separation, depth,
/// a Remove stroke and Save copy. On the iPhone 11 Pro Max the 30 s auto-lock suspended the app in the middle of the
/// first depth-model load, which then never finished while the person waited. Each operation holds a token for its
/// whole run and releases it on completion, failure and cancellation (a `defer` in its task); with no token held the
/// system's normal auto-lock applies again. The idle timer is re-applied at each activation, because iOS does not keep
/// a value set before the scene became active.
@MainActor
enum KeepAwake {
    private static var holders: [UUID: String] = [:]
    private static var observer: NSObjectProtocol?
    /// DEBUG `--keep-awake`: watched diagnostic sessions keep the phone awake throughout.
    static var debugAlways = false

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply(reason: "active") }
        }
    }

    /// Starts holding the phone awake for `reason`; pass the token to `end` when the work stops, however it stops.
    static func begin(_ reason: String) -> UUID {
        let token = UUID()
        holders[token] = reason
        apply(reason: "\(reason) started")
        return token
    }

    static func end(_ token: UUID) {
        guard let reason = holders.removeValue(forKey: token) else { return }
        apply(reason: "\(reason) ended")
    }

    /// Operations holding the phone awake now (tests and diagnostics).
    static var activeReasons: [String] { holders.values.sorted() }

    private static func apply(reason: String) {
        let disabled = !holders.isEmpty || debugAlways
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
        DiagnosticTrace.note("app: auto-lock \(disabled ? "held off" : "restored") (\(reason))")
    }
}
