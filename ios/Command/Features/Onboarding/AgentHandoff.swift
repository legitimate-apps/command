//
//  AgentHandoff.swift
//  Command
//
//  "Hand to your AI agent": complete setup instructions someone can paste into Claude,
//  ChatGPT or another agent, which can then walk them through setup or do it for them.
//
//  One pure function builds the text, so it is unit-tested (right commands and URLs per path,
//  no personal data) and the in-app sheet is only a rendering of it. The web twin lives at
//  https://legitimateapps.com/command/setup/agent.txt and the text links to it.
//

import Foundation

enum AgentHandoff {
    /// Which setup the brief leads with.
    enum Path: String, CaseIterable, Sendable {
        /// Nothing chosen yet: every option, Cloud first.
        case undecided
        case cloud
        case railway
        case docker
        /// A server that already runs somewhere.
        case existing

        init(_ option: ServerHostingOption) {
            switch option {
            case .railway:    self = .railway
            case .selfHosted: self = .docker
            case .existing:   self = .existing
            }
        }
    }

    static let serverPlaceholder = "<your server address>"
    static let tokenPlaceholder = "<access token>"

    /// The complete brief. `serverURL` fills in the MCP endpoint and health check when the
    /// address is known; otherwise a placeholder the agent asks for.
    static func instructions(path: Path, serverURL: String?) -> String {
        let cloud = ServerSetupGuide.cloudURL.absoluteString
        let known = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let server: String = {
            if path == .cloud { return cloud }
            if let known, !known.isEmpty { return known }
            return serverPlaceholder
        }()
        let selfHosted = path != .cloud

        var sections: [String] = [header(path: path)]
        switch path {
        case .undecided:
            sections += [cloudSection(), railwaySection(), dockerSection(), existingSection()]
        case .cloud:
            sections += [cloudSection()]
        case .railway:
            sections += [railwaySection()]
        case .docker:
            sections += [dockerSection()]
        case .existing:
            sections += [existingSection()]
        }
        if selfHosted { sections.append(aiKeySection()) }
        sections.append(mcpSection(server: server))
        sections.append(troubleshootingSection(server: server, selfHosted: selfHosted))
        if path != .undecided { sections.append(otherOptionsSection(path: path)) }
        sections.append(linksSection())
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Sections

    private static func header(path: Path) -> String {
        let focus: String
        switch path {
        case .undecided: focus = "They haven't chosen how to run it yet. Recommend Command Cloud unless they want to host it themselves."
        case .cloud:     focus = "They chose Command Cloud."
        case .railway:   focus = "They chose to host their own server on Railway."
        case .docker:    focus = "They chose to run their own server with Docker on their computer."
        case .existing:  focus = "They are connecting to a server that already exists."
        }
        return """
        # Set up Command — instructions for an AI agent

        You're helping someone set up Command, a planner app for iPhone, iPad and Mac: calendar, \
        quick notes (typed or spoken), goals, tasks, people, and an AI assistant. The app talks to \
        a Command server. \(focus)

        Walk them through the steps one at a time, or do the steps for them where you have access \
        (a terminal, their Railway account). Confirm before anything that costs money.
        """
    }

    private static func cloudSection() -> String {
        """
        ## Command Cloud (recommended, free)
        1. In the app, choose "Command Cloud" and tap Continue. Server: \(ServerSetupGuide.cloudURL.absoluteString)
        2. Create an account: a username and a password of 8+ characters.
        3. Done. Notes, calendar, tasks, people, goals and Claude Code (MCP) are free. The in-app \
        assistant is part of Command Pro, a subscription in the app. Nothing to install.
        """
    }

    private static func railwaySection() -> String {
        """
        ## Their own server on Railway (about $5/month, paid to Railway)
        1. Open \(ServerSetupGuide.railwayTemplateURL.absoluteString), sign in to Railway and press \
        Deploy Now. The template sets up the image, a /data volume and a public domain.
        2. When the deploy is green, open the service → Settings → Networking and copy its https:// address.
        3. Check it: <address>/api/health should return JSON with "service": "command".
        4. In the app: "My own server" → "Host it on Railway" → Connect, paste the address, then \
        create an account. The first account owns the server and sign-up closes behind it.
        """
    }

    private static func dockerSection() -> String {
        """
        ## Their own server with Docker (free)
        1. Install Docker Desktop on a Mac or PC that stays on: \(ServerSetupGuide.dockerDesktopURL.absoluteString)
        2. In Terminal (Mac) or PowerShell (Windows), run:
           \(ServerSetupGuide.dockerRunCommand)
        3. Find the computer's local IP address (Wi-Fi settings), for example 192.168.1.10.
        4. In the app: "My own server" → "Run it on my computer" → Connect, enter \
        http://<that IP>:9071 on the same Wi-Fi, then create an account. The first account owns the server.
        5. To use it away from home, put it behind Tailscale or Cloudflare Tunnel and connect with that https:// address.
        """
    }

    private static func existingSection() -> String {
        """
        ## A server that already exists
        1. In the app: "My own server" → "I have an address", enter it (https:// is added if missing).
        2. Sign in, or create an account if sign-up is open. If it's closed, ask the server's owner \
        for an invite link and open it on this device.
        """
    }

    private static func aiKeySection() -> String {
        """
        ## The assistant's AI key (own server only, optional)
        The in-app assistant runs on the server owner's OpenRouter key; usage is billed by \
        OpenRouter to that key, and the key stays on their server. Create one at \
        \(ServerSetupGuide.openRouterKeysURL.absoluteString), then either:
        - paste it in the app when it asks ("Add your AI key", also under Account → Server), or
        - set COMMAND_AI_API_KEY=<key> on the server (Railway: the service's Variables; Docker: \
        docker rm -f command, then re-run the docker run command with -e COMMAND_AI_API_KEY=<key> \
        added before the image name — the data volume is kept).
        Skipping is fine; everything except the assistant works without it.
        """
    }

    private static func mcpSection(server: String) -> String {
        """
        ## Connect Claude Code (MCP)
        - Endpoint: \(server)/mcp (Streamable HTTP)
        - Auth header: Authorization: Bearer \(tokenPlaceholder)
        - The token is in the app: Account → MCP access token → Reveal token. It gives access to \
        exactly one account; regenerating it there revokes the old one.
        - Claude Code:
          claude mcp add --transport http command \(server)/mcp --header "Authorization: Bearer \(tokenPlaceholder)"
        - Then call the command_whoami tool first.
        """
    }

    private static func troubleshootingSection(server: String, selfHosted: Bool) -> String {
        var lines = [
            "## If something doesn't work",
            "- Health check: open \(server)/api/health — it should return JSON with \"service\": \"command\".",
        ]
        if selfHosted {
            lines += [
                "- Server at home: the phone must be on the same Wi-Fi, using http://<IP>:9071. Allow port 9071 through the computer's firewall.",
                "- iOS allows plain http:// only for local addresses; a public hostname needs its https:// address.",
                "- Signing in over plain http on a home network works: the session cookie is marked Secure automatically only on HTTPS. Leave COMMAND_COOKIE_SECURE unset.",
                "- Railway: check the deploy logs, and that the /data volume is attached.",
            ]
        } else {
            lines.append("- \"Couldn't reach\": check the device is online, then try again in a minute.")
        }
        return lines.joined(separator: "\n")
    }

    private static func otherOptionsSection(path: Path) -> String {
        var others: [String] = []
        if path != .cloud { others.append("Command Cloud (\(ServerSetupGuide.cloudURL.absoluteString), free)") }
        if path != .railway { others.append("Railway (\(ServerSetupGuide.railwayTemplateURL.absoluteString))") }
        if path != .docker { others.append("Docker on their own computer") }
        return "## Other options\n" + others.joined(separator: ", ")
            + ". Switch any time in the app: Account → Server → Switch server."
    }

    private static func linksSection() -> String {
        """
        ## More
        - Setup guide with screenshots: \(ServerSetupGuide.helpURL.absoluteString)
        - Latest version of these instructions: \(ServerSetupGuide.agentBriefURL.absoluteString)
        """
    }
}
