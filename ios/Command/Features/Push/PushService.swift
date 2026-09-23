//
//  PushService.swift
//  Command
//
//  APNs registration for reminder pushes. After sign-in the app asks for notification permission
//  and registers for remote notifications; the device token (delivered to the app delegate) is
//  hex-encoded and POSTed to the server, which pushes due reminders to it. Failures are silent —
//  the simulator (and a build without the push entitlement) simply never gets a token, and the
//  rest of the app is unaffected.
//

import SwiftUI
import UserNotifications

@MainActor
final class PushService {
    /// Which REST surface owns this device's token: an operator session registers via
    /// /api/push, an invited delegatee via /api/my/push (the server stamps + routes those).
    enum Route { case operatorAccount, delegatee }

    /// The app delegate forwards the device token here (it lives outside the SwiftUI tree).
    static weak var shared: PushService?

    private var client: APIClient?
    private var route: Route = .operatorAccount
    private var lastToken: String?
    private var registrationTask: Task<Void, Never>?

    init() { PushService.shared = self }

    /// Request notification permission and, if granted, register for remote notifications. Safe to
    /// call repeatedly (e.g. on every sign-in) — the OS coalesces registration.
    func enable(client: APIClient, route: Route = .operatorAccount) {
        self.client = client
        self.route = route
        if let lastToken {
            register(token: lastToken, client: client)
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called by the app delegate with the raw APNs token; hex-encode and register it server-side.
    func handleToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastToken = hex
        guard let client else { return }
        register(token: hex, client: client)
    }

    private func register(token: String, client: APIClient) {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        registrationTask?.cancel()
        let route = self.route
        registrationTask = Task {
            switch route {
            case .operatorAccount: try? await client.registerPush(token: token, environment: environment)
            case .delegatee: try? await client.registerMyPush(token: token, environment: environment)
            }
        }
    }

    /// On sign-out, drop this device's token so a signed-out device stops receiving the account's
    /// reminders (best-effort).
    func disable() async {
        registrationTask?.cancel()
        await registrationTask?.value
        registrationTask = nil
        defer { client = nil }
        guard let hex = lastToken, let client else { return }
        switch route {
        case .operatorAccount: try? await client.unregisterPush(token: hex)
        case .delegatee: try? await client.unregisterMyPush(token: hex)
        }
    }

    /// Forget the authenticated client without making a request (session expiry/account deletion).
    func reset() {
        registrationTask?.cancel()
        registrationTask = nil
        client = nil
    }
}

/// Minimal app delegate: SwiftUI has no direct hook for the APNs token callbacks, so we adopt one
/// via `@UIApplicationDelegateAdaptor` purely to forward the device token to `PushService`.
final class CommandAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Without a delegate iOS silently drops a notification that arrives while the app is in
        // the foreground — so a reminder due while the user is looking at Command never showed.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared?.handleToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / missing entitlement — reminders still work in-app; only OS push is unavailable.
    }
}
