//
//  CommandCloudSetupTests.swift
//  CommandTests
//
//  Command Cloud + guided onboarding (docs/specs/2026-09-23-command-cloud.md): the server-info
//  contract, the setup decisions in `SetupFlow`, the agent hand-off brief, and the two new
//  endpoints on the wire. Each test pins a decision a regression would silently change —
//  e.g. offering "Create account" on a server whose owner closed sign-up, nagging a Cloud user
//  for an OpenRouter key, or a brief that tells an agent the wrong docker command.
//

import XCTest
@testable import Command

final class ServerInfoTests: XCTestCase {
    private func decode(_ json: String) throws -> ServerInfo {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(ServerInfo.self, from: Data(json.utf8))
    }

    func testDecodesTheSpecResponse() throws {
        let info = try decode("""
        {"service":"command","version":"1.1.0","kind":"cloud","registration_open":true,
         "ai":{"configured":true,"requires_subscription":true,"key_settable":false}}
        """)
        XCTAssertTrue(info.isCloud)
        XCTAssertFalse(info.isSelfHosted)
        XCTAssertTrue(info.allowsRegistration)
        XCTAssertTrue(info.aiConfigured)
        XCTAssertTrue(info.assistantRequiresSubscription)
        XCTAssertFalse(info.aiKeySettable)
    }

    func testAPartialResponseStillDecodesWithSafeDefaults() throws {
        let info = try decode(#"{"service":"command","kind":"self"}"#)
        XCTAssertTrue(info.isSelfHosted)
        XCTAssertTrue(info.allowsRegistration, "unknown sign-up state behaves as before: offered")
        XCTAssertFalse(info.aiConfigured)
        XCTAssertFalse(info.aiKeySettable, "never offer the key step on a guess")
    }
}

final class SetupFlowTests: XCTestCase {
    private let cloud = ServerInfo(service: "command", version: "1.1.0", kind: "cloud", registrationOpen: true,
                                   ai: .init(configured: true, requiresSubscription: true, keySettable: false))
    private let freshSelf = ServerInfo(service: "command", version: "1.1.0", kind: "self", registrationOpen: true,
                                       ai: .init(configured: false, requiresSubscription: false, keySettable: true))
    private let ownedSelf = ServerInfo(service: "command", version: "1.1.0", kind: "self", registrationOpen: false,
                                       ai: .init(configured: true, requiresSubscription: false, keySettable: true))
    private let lan = "http://192.168.1.10:9071"

    func testTheCloudAddressLivesInOnePlace() {
        XCTAssertEqual(ServerSetupGuide.cloudURL.absoluteString, "https://cloud.legitimateapps.com")
    }

    // MARK: Labels

    func testTheServerSaysWhatItIsAndTheAddressIsOnlyAFallback() {
        XCTAssertTrue(SetupFlow.isCloud(info: cloud, serverURL: lan), "the server's own kind wins")
        XCTAssertFalse(SetupFlow.isCloud(info: freshSelf, serverURL: "https://cloud.legitimateapps.com"))
        XCTAssertTrue(SetupFlow.isCloud(info: nil, serverURL: "https://cloud.legitimateapps.com/"))
        XCTAssertTrue(SetupFlow.isCloud(info: nil, serverURL: "HTTPS://Cloud.LegitimateApps.com"))
        XCTAssertFalse(SetupFlow.isCloud(info: nil, serverURL: "https://command.example.com"))
        XCTAssertFalse(SetupFlow.isCloud(info: nil, serverURL: ""))
    }

    func testLabels() {
        XCTAssertEqual(SetupFlow.serverLabel(info: cloud, serverURL: ServerSetupGuide.cloudURL.absoluteString),
                       "Command Cloud")
        XCTAssertEqual(SetupFlow.serverLabel(info: freshSelf, serverURL: lan), "192.168.1.10:9071")
        XCTAssertEqual(SetupFlow.serverLabel(info: nil, serverURL: "https://command.example.com"),
                       "command.example.com")
        XCTAssertEqual(SetupFlow.serverKindLabel(info: cloud, serverURL: ""), "Command Cloud")
        XCTAssertEqual(SetupFlow.serverKindLabel(info: freshSelf, serverURL: lan), "Self-hosted")
    }

    // MARK: Account step

    func testCreateAccountIsHiddenOnlyWhenTheServerClosedSignUp() {
        XCTAssertTrue(SetupFlow.canCreateAccount(info: cloud))
        XCTAssertTrue(SetupFlow.canCreateAccount(info: freshSelf))
        XCTAssertFalse(SetupFlow.canCreateAccount(info: ownedSelf))
        XCTAssertTrue(SetupFlow.canCreateAccount(info: nil), "an older server (404) keeps today's behaviour")
    }

    func testWhichModeTheAccountScreenOpensIn() {
        XCTAssertTrue(SetupFlow.startsOnCreateAccount(info: freshSelf, justChoseServer: false),
                      "an ownerless server's first account is its owner — that's a sign-up")
        XCTAssertTrue(SetupFlow.startsOnCreateAccount(info: cloud, justChoseServer: true))
        XCTAssertFalse(SetupFlow.startsOnCreateAccount(info: cloud, justChoseServer: false),
                       "someone coming back to Cloud is signing in")
        XCTAssertFalse(SetupFlow.startsOnCreateAccount(info: ownedSelf, justChoseServer: true))
        XCTAssertFalse(SetupFlow.startsOnCreateAccount(info: nil, justChoseServer: true))
    }

    // MARK: AI key step

    func testTheAIKeyStepAppearsOnlyForAFreshSelfHostedServer() {
        XCTAssertTrue(SetupFlow.offersAIKey(info: freshSelf, skipped: false))
        XCTAssertFalse(SetupFlow.offersAIKey(info: freshSelf, skipped: true), "skipping is remembered")
        XCTAssertFalse(SetupFlow.offersAIKey(info: cloud, skipped: false), "Cloud never asks for a key")
        XCTAssertFalse(SetupFlow.offersAIKey(info: ownedSelf, skipped: false), "already configured")
        XCTAssertFalse(SetupFlow.offersAIKey(info: nil, skipped: false), "older server: no step")
        var envManaged = freshSelf
        envManaged.ai?.keySettable = false
        XCTAssertFalse(SetupFlow.offersAIKey(info: envManaged, skipped: false), "key comes from env")
    }

    func testStageOrder() {
        XCTAssertEqual(SetupFlow.firstStage(info: freshSelf, aiKeySkipped: false, tutorialSeen: false), .aiKey)
        XCTAssertEqual(SetupFlow.firstStage(info: cloud, aiKeySkipped: false, tutorialSeen: false), .ready)
        XCTAssertNil(SetupFlow.firstStage(info: cloud, aiKeySkipped: false, tutorialSeen: true),
                     "the tutorial shows once")
        XCTAssertEqual(SetupFlow.firstStage(info: freshSelf, aiKeySkipped: false, tutorialSeen: true), .aiKey,
                       "a missing key is still worth asking about after the tutorial was seen")
        XCTAssertEqual(SetupFlow.stage(after: .aiKey, tutorialSeen: false), .ready)
        XCTAssertNil(SetupFlow.stage(after: .aiKey, tutorialSeen: true))
        XCTAssertNil(SetupFlow.stage(after: .ready, tutorialSeen: false))
    }

    func testSkippedKeyIsRememberedPerServer() {
        XCTAssertNotEqual(SetupFlow.aiKeySkippedKey(for: "https://a.example.com"),
                          SetupFlow.aiKeySkippedKey(for: "https://b.example.com"))
    }

    // MARK: Tutorial

    func testTutorialHasAtMostThreeCardsEachWithOneAction() {
        for (isCloud, unlocked, configured) in [(true, false, true), (true, true, true),
                                                (false, true, false), (false, true, true)] {
            let cards = SetupFlow.tutorialCards(isCloud: isCloud, assistantUnlocked: unlocked, aiConfigured: configured)
            XCTAssertLessThanOrEqual(cards.count, 3)
            XCTAssertEqual(Set(cards.map(\.id)).count, cards.count)
            XCTAssertEqual(cards.first?.action, .capture)
            XCTAssertTrue(cards.contains { $0.id == "mcp" && $0.action == .account })
        }
    }

    func testTheAssistantCardTellsTheTruthAboutThisServer() {
        func assistant(_ cloud: Bool, _ unlocked: Bool, _ configured: Bool) -> TutorialCard {
            SetupFlow.tutorialCards(isCloud: cloud, assistantUnlocked: unlocked, aiConfigured: configured)
                .first { $0.id == "assistant" }!
        }
        let cloudFree = assistant(true, false, true)
        XCTAssertTrue(cloudFree.detail.contains("Command Pro"))
        XCTAssertEqual(cloudFree.action, .assistant, "opens the Assistant tab, whose gate explains Pro")
        XCTAssertEqual(assistant(true, true, true).action, .newChat)
        let selfNoKey = assistant(false, true, false)
        XCTAssertEqual(selfNoKey.action, .account)
        XCTAssertTrue(selfNoKey.detail.contains("AI key"))
        XCTAssertEqual(assistant(false, true, true).action, .newChat)
    }

    func testTutorialActionsRouteThroughTheShellIntents() {
        XCTAssertEqual(TutorialCard.Action.capture.intent, .capture)
        XCTAssertEqual(TutorialCard.Action.newChat.intent, .newChat)
        XCTAssertEqual(TutorialCard.Action.assistant.intent, .go(.assistant))
        XCTAssertEqual(TutorialCard.Action.account.intent, .go(.account))
    }

    // MARK: Hand-off path

    func testHandoffPathFollowsTheServerThenTheChoice() {
        XCTAssertEqual(SetupFlow.handoffPath(info: cloud, serverURL: ServerSetupGuide.cloudURL.absoluteString,
                                             chosen: nil), .cloud)
        XCTAssertEqual(SetupFlow.handoffPath(info: freshSelf, serverURL: lan, chosen: .selfHosted), .docker)
        XCTAssertEqual(SetupFlow.handoffPath(info: freshSelf, serverURL: lan, chosen: .railway), .railway)
        XCTAssertEqual(SetupFlow.handoffPath(info: nil, serverURL: lan, chosen: nil), .existing)
        XCTAssertEqual(SetupFlow.handoffPath(info: nil, serverURL: "", chosen: nil), .undecided)
    }
}

final class AgentHandoffTests: XCTestCase {
    private let docker = ServerSetupGuide.dockerRunCommand
    private let railway = "https://railway.com/deploy/command"
    private let cloud = "https://cloud.legitimateapps.com"

    func testTheDockerCommandIsTheExactPublishedOne() {
        XCTAssertEqual(docker, "docker run -d --name command --restart unless-stopped -p 9071:8000 "
                       + "-v command-data:/data ghcr.io/legitimate-apps/command-server")
    }

    func testEveryBriefLinksTheWebGuideAndCoversMCPAndTroubleshooting() {
        for path in AgentHandoff.Path.allCases {
            let text = AgentHandoff.instructions(path: path, serverURL: nil)
            XCTAssertTrue(text.contains("https://legitimateapps.com/command/setup"), "\(path)")
            XCTAssertTrue(text.contains("https://legitimateapps.com/command/setup/agent.txt"), "\(path)")
            XCTAssertTrue(text.contains("/mcp"), "\(path)")
            XCTAssertTrue(text.contains("Authorization: Bearer"), "\(path)")
            XCTAssertTrue(text.contains("claude mcp add --transport http command"), "\(path)")
            XCTAssertTrue(text.contains("Account → MCP access token"), "\(path): where the token lives")
            XCTAssertTrue(text.contains("/api/health"), "\(path)")
        }
    }

    func testUndecidedCoversEveryPath() {
        let text = AgentHandoff.instructions(path: .undecided, serverURL: nil)
        XCTAssertTrue(text.contains(cloud))
        XCTAssertTrue(text.contains(railway))
        XCTAssertTrue(text.contains(docker))
        XCTAssertTrue(text.contains("COMMAND_AI_API_KEY"))
        XCTAssertTrue(text.contains("https://openrouter.ai/keys"))
        XCTAssertTrue(text.contains("same Wi-Fi"))
        XCTAssertTrue(text.contains("COMMAND_COOKIE_SECURE"), "the Secure-cookie note for LAN sign-in")
        XCTAssertTrue(text.contains(AgentHandoff.serverPlaceholder))
    }

    func testCloudBriefIsAboutCloud() {
        let text = AgentHandoff.instructions(path: .cloud, serverURL: nil)
        XCTAssertTrue(text.contains("\(cloud)/mcp"), "the MCP endpoint is Cloud's")
        XCTAssertTrue(text.contains("\(cloud)/api/health"))
        XCTAssertTrue(text.contains("Command Pro"))
        XCTAssertFalse(text.contains(docker), "no docker walkthrough for a Cloud user")
        XCTAssertFalse(text.contains("COMMAND_AI_API_KEY"), "Cloud users never need a model key")
        XCTAssertFalse(text.contains(AgentHandoff.serverPlaceholder))
    }

    func testCloudBriefIgnoresAnotherServersAddress() {
        let text = AgentHandoff.instructions(path: .cloud, serverURL: "https://command.example.com")
        XCTAssertFalse(text.contains("command.example.com"))
    }

    func testRailwayBrief() {
        let text = AgentHandoff.instructions(path: .railway, serverURL: nil)
        XCTAssertTrue(text.contains(railway))
        XCTAssertTrue(text.contains("Settings → Networking"))
        XCTAssertTrue(text.contains("COMMAND_AI_API_KEY"))
        XCTAssertFalse(text.contains(docker))
        XCTAssertTrue(text.contains(cloud), "mentions Cloud as the alternative")
    }

    func testDockerBrief() {
        let text = AgentHandoff.instructions(path: .docker, serverURL: nil)
        XCTAssertTrue(text.contains(docker))
        XCTAssertTrue(text.contains(":9071"))
        XCTAssertTrue(text.contains("Tailscale"))
        XCTAssertTrue(text.contains("-e COMMAND_AI_API_KEY"))
    }

    func testAKnownServerFillsInTheEndpoints() {
        let text = AgentHandoff.instructions(path: .existing, serverURL: "https://command.example.com/")
        XCTAssertTrue(text.contains("https://command.example.com/mcp"), "trailing slash trimmed")
        XCTAssertTrue(text.contains("https://command.example.com/api/health"))
        XCTAssertFalse(text.contains(AgentHandoff.serverPlaceholder))
        XCTAssertTrue(text.contains("invite"))
    }

    func testNoPersonalDataInAnyBrief() throws {
        let email = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        let ipv4 = try NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)
        for path in AgentHandoff.Path.allCases {
            let text = AgentHandoff.instructions(path: path, serverURL: nil)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertEqual(email.numberOfMatches(in: text, range: range), 0, "\(path): no email addresses")
            for match in ipv4.matches(in: text, range: range) {
                let ip = String(text[Range(match.range, in: text)!])
                XCTAssertTrue(ip.hasPrefix("192.168.1."), "\(path): only documentation-style IPs, got \(ip)")
            }
            XCTAssertNil(text.range(of: #"cmd_[a-z]"#, options: .regularExpression), "\(path): no real token")
            XCTAssertNil(text.range(of: #"sk-or-v1-[A-Za-z0-9]"#, options: .regularExpression), "\(path): no real key")
            XCTAssertFalse(text.contains("/Users/"), "\(path): no machine paths")
            // Every URL points at a public, expected host.
            let urls = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)
            for match in urls.matches(in: text, range: range) {
                let host = String(text[Range(match.range(at: 1), in: text)!])
                let allowed = ["cloud.legitimateapps.com", "legitimateapps.com", "railway.com",
                               "www.docker.com", "openrouter.ai"]
                XCTAssertTrue(allowed.contains(host), "\(path): unexpected host \(host)")
            }
        }
    }
}

// MARK: - On the wire

private final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastMethod: String?
    nonisolated(unsafe) static var lastPath: String?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int, body: String) {
        self.status = status; self.body = Data(body.utf8)
        lastMethod = nil; lastPath = nil; lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastMethod = request.httpMethod
        Self.lastPath = request.url?.path
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ServerEndpointsWireTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return APIClient(baseURL: URL(string: "https://command.example.com")!, configuration: config)
    }

    func testServerInfoIsAPublicGet() async throws {
        RecordingProtocol.reset(status: 200, body: """
        {"service":"command","version":"1.1.0","kind":"self","registration_open":false,
         "ai":{"configured":false,"requires_subscription":false,"key_settable":true}}
        """)
        let info = try await client().serverInfo()
        XCTAssertEqual(RecordingProtocol.lastMethod, "GET")
        XCTAssertEqual(RecordingProtocol.lastPath, "/api/server/info")
        XCTAssertFalse(info.allowsRegistration)
        XCTAssertTrue(info.aiKeySettable)
    }

    func testAnOlderServer404sAndTheCallerGetsAnError() async {
        RecordingProtocol.reset(status: 404, body: #"{"detail":"Not Found"}"#)
        do {
            _ = try await client().serverInfo()
            XCTFail("a 404 must surface so callers can fall back")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 404, code: nil, message: nil))
        }
    }

    func testSettingTheAIKeyPutsTheSnakeCasedBody() async throws {
        RecordingProtocol.reset(status: 200, body: "{}")
        try await client().setServerAIKey("sk-or-example")
        XCTAssertEqual(RecordingProtocol.lastMethod, "PUT")
        XCTAssertEqual(RecordingProtocol.lastPath, "/api/server/ai-key")
        let json = try JSONSerialization.jsonObject(with: RecordingProtocol.lastBody ?? Data()) as? [String: String]
        XCTAssertEqual(json, ["api_key": "sk-or-example"])
    }

    func testANotOwnerRefusalCarriesItsCode() async {
        RecordingProtocol.reset(status: 403, body: """
        {"error":{"code":"not_owner","message":"Only the server's owner can set the AI key."}}
        """)
        do {
            try await client().setServerAIKey("sk-or-example")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? APIError,
                           .http(status: 403, code: "not_owner", message: "Only the server's owner can set the AI key."))
        }
    }
}
