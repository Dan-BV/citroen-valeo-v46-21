#if canImport(UIKit)
import UIKit
#endif

/// Keeps the screen from sleeping while a session is running.
///
/// The reason is not comfort. When the screen sleeps the app is suspended, and
/// during the suspension the ECU drops the diagnostic session - measured on
/// 2026-09-10, where an 11 s and a 41 s gap in the technical log are each
/// followed by every page answering `NO DATA`
/// (`out/drives/2026-09-10_ios_baseline.md`). Holding the screen awake removes
/// the cause rather than recovering from it.
///
/// The UIKit dependency is confined to this file so the session logic, which is
/// a port of the Android one, stays free of it.
enum DeviceAwake {

    /// Nested calls are counted, so two owners cannot release each other's
    /// hold. In practice there is one, but the flag is global to the process
    /// and getting it stuck on costs the user their battery.
    private static var holds = 0

    static func hold() {
        holds += 1
        apply()
    }

    static func release() {
        holds = max(0, holds - 1)
        apply()
    }

    private static func apply() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = holds > 0
        #endif
    }
}
