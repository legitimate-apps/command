//
//  IntentAPI.swift
//  Command
//
//  The bridge between the App Intents surface (Siri, Shortcuts, Spotlight) and the
//  Command server. App Intents run in a *separate* launch context from the app's
//  `AppState`/`APIClient` — often the app is woken in the background purely to run
//  an intent — so this layer builds its own `APIClient` on demand. It shares the
//  process-wide `HTTPCookieStorage.shared` (the default `URLSessionConfiguration`
//  uses it), which is where the app persists its httpOnly `command_session` cookie,
//  so a Shortcut is authenticated exactly when the app is signed in — no token
//  plumbing, no re-login. When the session is missing/expired the server answers 401
//  and we translate that into an actionable `CommandIntentError.notSignedIn`.
//

import Foundation
import AppIntents

/// Errors surfaced to Siri / the Shortcuts editor. Conforming to
/// `CustomLocalizedStringResourceConvertible` lets App Intents speak/show the message
/// instead of a generic "the app cancelled the request".
enum CommandIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    /// No server has been chosen yet (a fresh install that hasn't finished onboarding).
    case noServer
    /// No valid session — the user needs to open Command and sign in first.
    case notSignedIn
    /// The server rejected the request; carries the server's human message when present.
    case server(String)
    /// A required piece of input resolved to empty (e.g. blank note text).
    case emptyInput(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer:
            return "Command isn't connected to a server yet. Open the app to finish setting it up, then try again."
        case .notSignedIn:
            return "You're not signed in to Command. Open the app and sign in, then try again."
        case .server(let message):
            return "Command couldn't finish that: \(message)"
        case .emptyInput(let field):
            return "Please provide \(field)."
        }
    }
}

/// Namespace for building an authenticated client and running a request with uniform
/// error translation. Every intent goes through `run` so a 401 anywhere becomes a
/// single, friendly "sign in" message.
enum IntentAPI {
    /// A fresh client pointed at the configured server, sharing the app's cookie jar.
    ///
    /// Throws `.noServer` rather than falling back: there is no default server, and App
    /// Shortcuts are registered at install — so an intent can run before onboarding has
    /// chosen one. (The old `URL(string: "")!` fallback crashed exactly there.)
    static func makeClient() throws -> APIClient {
        let raw = UserDefaults.standard.string(forKey: AppState.urlKey) ?? AppState.defaultServerURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil
        else { throw CommandIntentError.noServer }
        // `.default` configuration ⇒ `httpCookieStorage == HTTPCookieStorage.shared`,
        // the same persistent jar the app's `APIClient` writes the session cookie into.
        return APIClient(baseURL: url)
    }

    /// Execute an authenticated call, mapping transport failures to `CommandIntentError`.
    /// A 401 on an authenticated route means the session is gone → `.notSignedIn`.
    static func run<T>(_ work: (APIClient) async throws -> T) async throws -> T {
        let client = try makeClient()
        do {
            return try await work(client)
        } catch let error as APIError {
            if error.isUnauthorized { throw CommandIntentError.notSignedIn }
            if case .http(_, _, let message) = error {
                throw CommandIntentError.server(message ?? "the request failed.")
            }
            throw CommandIntentError.server(error.errorDescription ?? "the request failed.")
        }
    }
}

// MARK: - Date / string helpers shared across intents

enum IntentFormat {
    /// ISO-8601 with the internet date-time profile — the server's canonical instant form.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses either an instant with fractional seconds or a plain internet date-time
    /// (the two shapes the server emits) back to a `Date`.
    static func date(from isoString: String) -> Date? {
        if let d = isoWithFraction.date(from: isoString) { return d }
        return iso.date(from: isoString)
    }
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Local wall-clock bounds [start, end) for a calendar day, as server ISO strings.
    static func dayBounds(for day: Date, calendar: Calendar = .current) -> (start: String, end: String) {
        let startOfDay = calendar.startOfDay(for: day)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
        return (iso.string(from: startOfDay), iso.string(from: endOfDay))
    }

    /// "Sat, Jul 4" — a compact day label used in dialogs and entity subtitles.
    static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f.string(from: date)
    }
}
