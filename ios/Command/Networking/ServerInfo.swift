//
//  ServerInfo.swift
//  Command
//
//  `GET /api/server/info` — the public, unauthenticated description of a Command server
//  (spec: docs/specs/2026-09-23-command-cloud.md). The app reads it to label the server
//  (Cloud vs your own), to decide whether "Create account" is offered, and whether to show
//  the "Add your AI key" step.
//
//  Every field is optional on the wire side so a partial or future-shaped response still
//  decodes; the computed properties hold the safe defaults. A server too old to have the
//  endpoint 404s, and callers treat `nil` as "behave exactly as before".
//

import Foundation

struct ServerInfo: Codable, Equatable, Sendable {
    struct AI: Codable, Equatable, Sendable {
        /// A model key is available to the assistant.
        var configured: Bool?
        /// Command Pro gates the assistant on this server.
        var requiresSubscription: Bool?
        /// The owner may set a key from the app (self-hosted, no key supplied by env).
        var keySettable: Bool?
    }

    var service: String?
    var version: String?
    /// "cloud" | "self".
    var kind: String?
    /// False once a self-hosted server has its owner.
    var registrationOpen: Bool?
    var ai: AI?

    var isCloud: Bool { kind == "cloud" }
    var isSelfHosted: Bool { kind == "self" }
    /// Unknown ⇒ open: an older server always showed "Create account" and let the server refuse.
    var allowsRegistration: Bool { registrationOpen ?? true }
    var aiConfigured: Bool { ai?.configured ?? false }
    var aiKeySettable: Bool { ai?.keySettable ?? false }
    var assistantRequiresSubscription: Bool { ai?.requiresSubscription ?? false }
}
