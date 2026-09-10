import SwiftUI

@main
struct ValeoApp: App {

    /// Held for the life of the process: UNUserNotificationCenter keeps its
    /// delegate weakly, and a released router silently stops the stop button
    /// on the stall reminder from working.
    private let router = NotificationRouter()

    init() {
        StallReminder.configure(router: router)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
