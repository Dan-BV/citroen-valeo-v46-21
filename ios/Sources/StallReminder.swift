import Foundation
import UserNotifications

/// Tells the user that a session is still running while the car has stopped
/// answering - the "engine off and walked away" case.
///
/// The trigger is deliberately one condition rather than several: no valid
/// reading for a while. That covers every way the car can go quiet - the
/// ignition off so the ECU drops the session and every page answers `NO DATA`,
/// the adapter losing power with the port, and the phone simply walking out of
/// range - without having to tell them apart, which from up here is not
/// reliably possible anyway.
///
/// It fires whatever state the app is in. With the screen held awake by
/// `DeviceAwake` the app is usually still in the foreground when this happens,
/// so a "only when backgrounded" rule would miss exactly the case worth
/// catching.
/// Kept at file scope rather than on the class: `configure` is nonisolated and
/// would not be able to reach main-actor-isolated statics.
private let stallCategoryId = "session-stall"
private let stallStopActionId = "session-stall-stop"
/// Kept out of the reminder ids so ending a session cannot clear it.
private let sessionEndedId = "session-ended"

/// Whether there is an app around this code at all.
///
/// The test bundle is deliberately not hosted by the app, so that
/// `xcodebuild test` needs no install and no signing - and in a bare test
/// runner `UNUserNotificationCenter.current()` raises: there is no bundle proxy
/// for the process. Nothing in the tests wants a reminder, so every entry point
/// below stands down rather than the session crashing on connect.
private let hasAppBundle = Bundle.main.bundleURL.pathExtension == "app"

@MainActor
final class StallReminder {

    static let shared = StallReminder()

    /// Invoked when the user taps the notification's stop button.
    var onStop: (() -> Void)?

    /// Quiet for this long and the car is not answering rather than hesitating.
    /// A stall of a few seconds is normal - the 2026-09-10 logs show gaps of 7
    /// and 11 seconds during ordinary use - so the threshold sits well past
    /// them.
    private let firstAfter: TimeInterval = 60

    /// A forgotten app should nag, but a phone in a pocket should not buzz all
    /// evening, so the reminders are spaced out and there is a last one.
    private let repeatEvery: TimeInterval = 600
    private let maxReminders = 3

    private var sent = 0
    private var lastSent: Date?
    /// Whether a reminder could actually be delivered. Worth surfacing:
    /// without the permission the app looks like it is watching the car
    /// while in fact nothing will ever be said.
    private(set) var authorized = false

    /// Registers the category once, at launch, so the stop button exists by the
    /// time a notification can carry it.
    nonisolated static func configure(router: UNUserNotificationCenterDelegate) {
        guard hasAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = router
        let stop = UNNotificationAction(
            identifier: stallStopActionId,
            title: "Остановить",
            options: [.destructive, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: stallCategoryId,
                                   actions: [stop],
                                   intentIdentifiers: [],
                                   options: [])
        ])
    }

    /// Asked for at the first connection rather than at launch: at launch the
    /// permission has no visible purpose, and a prompt without a reason is a
    /// prompt that gets denied.
    func prepare() async {
        guard hasAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            authorized = false
        default:
            authorized = true
        }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [sessionEndedId])
        reset()
    }

    /// A reading arrived, or a session started: the car is talking again.
    func reset() {
        sent = 0
        lastSent = nil
        clearDelivered()
    }

    /// The session ended - nothing left to remind anyone about.
    func sessionEnded() {
        reset()
    }

    /// The session ended because the link died, rather than because anyone
    /// asked. A separate notification from the stall reminder, and separate on
    /// purpose: that one asks whether to stop, this one reports that it
    /// already has, so it must survive the teardown that clears the other.
    func linkLost() {
        guard hasAppBundle, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Запись остановлена"
        content.body = "Связь с адаптером потеряна. "
            + "Если вы ушли от машины — так и должно быть."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: sessionEndedId,
                                  content: content,
                                  trigger: nil))
    }

    /// Called once a cycle with how long the car has been quiet.
    func stalled(for quiet: TimeInterval) {
        guard authorized, quiet >= firstAfter, sent < maxReminders else { return }
        if let last = lastSent, Date().timeIntervalSince(last) < repeatEvery { return }
        sent += 1
        lastSent = Date()
        post(quiet: quiet, last: sent == maxReminders)
    }

    private func post(quiet: TimeInterval, last: Bool) {
        guard hasAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "Машина не отвечает"
        let minutes = max(1, Int(quiet / 60))
        content.body = "Приложение опрашивает адаптер уже \(minutes) мин без ответа."
            + (last
               ? " Это последнее напоминание — запись продолжается."
               : " Если вы ушли от машины, остановите запись.")
        content.sound = .default
        content.categoryIdentifier = stallCategoryId
        // No trigger: deliver now. The decision to remind was already made here.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(stallCategoryId)-\(sent)",
                                  content: content,
                                  trigger: nil))
    }

    private func clearDelivered() {
        guard hasAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        let ids = (1...maxReminders).map { "\(stallCategoryId)-\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    fileprivate func handleStop() {
        onStop?()
        reset()
    }
}

/// Receives the notification's stop button.
///
/// Kept apart from `StallReminder` because the delegate callbacks are not
/// main-actor isolated, and this is the whole of the hop.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let stopped = response.actionIdentifier != UNNotificationDefaultActionIdentifier
            && response.actionIdentifier != UNNotificationDismissActionIdentifier
        Task { @MainActor in
            if stopped { StallReminder.shared.handleStop() }
            completionHandler()
        }
    }
}
