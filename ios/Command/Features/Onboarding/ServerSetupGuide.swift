//
//  ServerSetupGuide.swift
//  Command
//
//  What a new person needs to know before the app can do anything: Command talks to a server
//  that they run, and there is no default one. That is a deliberate product decision, not an
//  omission — their notes, their plans and their assistant conversations live on a machine they
//  control, and the app never phones anywhere else.
//
//  It is also, unavoidably, a wall in front of a brand-new App Store user. So this file holds
//  the actual instructions rather than a link to a docs site: the hosting choices, the real
//  commands, and what "done" looks like. Kept as pure data + pure functions so the content and
//  the URL handling are unit-testable and the view stays a rendering of them.
//

import Foundation

/// A way to get a Command server, in the order most people should consider them.
enum ServerHostingOption: String, CaseIterable, Identifiable, Sendable {
    /// Managed hosting. Costs a few dollars a month; needs no hardware and no networking.
    case railway
    /// Docker on a machine they already own. Free, but they have to reach it from the phone.
    case selfHosted
    /// Someone else already ran one — a partner's, or their own from another device.
    case existing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .railway:    return "Host it for me"
        case .selfHosted: return "Run it on my own machine"
        case .existing:   return "I already have a server"
        }
    }

    var subtitle: String {
        switch self {
        case .railway:    return "A few minutes on Railway. Around $5/month."
        case .selfHosted: return "Docker on a Mac or PC you own. Free."
        case .existing:   return "Enter its address and sign in."
        }
    }

    var systemImage: String {
        switch self {
        case .railway:    return "cloud"
        case .selfHosted: return "internaldrive"
        case .existing:   return "link"
        }
    }

    /// The honest trade-off, shown next to the choice rather than discovered afterwards.
    var tradeoff: String? {
        switch self {
        case .railway:
            return "Easiest, and reachable from anywhere. You pay Railway directly; "
                 + "Command takes no cut and never sees your data."
        case .selfHosted:
            return "Free and completely private, but your phone can only reach it from home "
                 + "unless you add a tunnel (Tailscale or Cloudflare Tunnel)."
        case .existing:
            return nil
        }
    }

    var steps: [SetupStep] { ServerSetupGuide.steps(for: self) }
}

/// One instruction. `command` is shown in a copyable monospaced block and `link` as a button,
/// when present.
struct SetupStep: Identifiable, Equatable, Sendable {
    let index: Int
    let title: String
    let detail: String
    var command: String? = nil
    var link: SetupLink? = nil

    var id: Int { index }
}

struct SetupLink: Equatable, Sendable {
    let title: String
    let url: URL
}

enum ServerSetupGuide {
    /// The server's source. Public, MIT-licensed.
    static let repositoryURL = URL(string: "https://github.com/legitimate-apps/command")!
    /// The same instructions on the web, with pictures, for doing this on a computer.
    static let helpURL = URL(string: "https://legitimateapps.com/command/setup")!
    /// Where "Open Railway" goes: the one-click template (the published image, a /data volume
    /// and a public domain), reached through the web guide's Railway section.
    static let railwayTemplateURL = URL(string: "https://legitimateapps.com/command/setup#railway")!
    static let dockerDesktopURL = URL(string: "https://www.docker.com/products/docker-desktop/")!

    /// Pulls the published image and keeps it running across restarts; data lives in a volume.
    static let dockerRunCommand =
        "docker run -d --name command --restart unless-stopped -p 9071:8000 "
        + "-v command-data:/data ghcr.io/legitimate-apps/command-server"

    static func steps(for option: ServerHostingOption) -> [SetupStep] {
        switch option {
        case .railway:      return railwaySteps
        case .selfHosted:   return selfHostedSteps
        case .existing:     return []
        }
    }

    private static let railwaySteps: [SetupStep] = [
        SetupStep(
            index: 1,
            title: "Deploy",
            detail: "Sign in to Railway and press Deploy. Everything is already set up.",
            link: SetupLink(title: "Open Railway", url: railwayTemplateURL)
        ),
        SetupStep(
            index: 2,
            title: "Copy your address",
            detail: "When it finishes, open the service and copy the https:// address under Settings → Networking."
        ),
        SetupStep(
            index: 3,
            title: "Connect",
            detail: "Paste it on the next screen and create your account. The first account owns the server."
        ),
    ]

    private static let selfHostedSteps: [SetupStep] = [
        SetupStep(
            index: 1,
            title: "Install Docker Desktop",
            detail: "On a Mac or PC that stays on.",
            link: SetupLink(title: "Get Docker Desktop", url: dockerDesktopURL)
        ),
        SetupStep(
            index: 2,
            title: "Start Command",
            detail: "Open Terminal (Mac) or PowerShell (Windows), paste this and press Return.",
            command: dockerRunCommand
        ),
        SetupStep(
            index: 3,
            title: "Connect",
            detail: "On the same Wi-Fi, enter the computer's address with :9071, like http://192.168.1.10:9071. "
                  + "Its Wi-Fi settings show the address."
        ),
    ]

    // MARK: - URL handling

    /// Tidy up what someone typed into something we can actually call.
    ///
    /// People paste addresses with a trailing slash, with the scheme missing, with a stray space
    /// from a copy, or with the path still attached. Rejecting those outright would be a wall at
    /// the worst possible moment, so normalise what is unambiguous and refuse only what is not.
    ///
    /// `http` is deliberately allowed: the most private setup in this guide is a box on your own
    /// LAN, which has no certificate. Warning about it is the view's job (see `isInsecure`).
    static func normalizedServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }

    /// True for a plain-http address, which is fine on a LAN and a bad idea over the internet.
    static func isInsecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "http" }

    /// True when the host is a private/local address, where plain http is entirely reasonable.
    static func isLocalAddress(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        // 100.64.0.0/10 — Tailscale and carrier-grade NAT. A tailnet IP is private to the tailnet,
        // and iOS permits plain http to an IP literal.
        if host.hasPrefix("100.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (64...127).contains(second) { return true }
        }
        return false
    }
}
