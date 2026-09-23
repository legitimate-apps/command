//
//  OnboardingView.swift
//  Command
//
//  The first thing a new person sees, and the only screen that has to justify itself.
//
//  Two roads, chosen on the welcome page: **Command Cloud** — free, nothing to run, the default
//  for almost everyone — or **My own server**, where the existing self-host guide lives (Railway,
//  Docker on a computer they own, or an address they already have). Every screen carries a
//  "Hand to AI" button in its top bar that copies the complete setup instructions for an agent.
//
//  It reads as a page from the planner itself: ink on paper, one accent, and — down the setup
//  steps — a numbered rail you tick off as you work, the way you'd check a list printed in
//  the margin. Panes turn like pages: a single short drift-and-fade in the direction of
//  travel, skipped entirely under Reduce Motion. Content and URL logic live in
//  `ServerSetupGuide`, `SetupFlow` and `AgentHandoff`; this file only renders them.
//
//  The same view, started at `.switchServer`, is Account → Server → "Switch server" (and the
//  sign-in screen's "Change server"), so there is one choice screen, not two.
//

import SwiftUI

/// Where the onboarding flow can be. Public so the DEBUG preview harness can start anywhere.
enum OnboardingStep: Hashable {
    case welcome
    /// The choice again, from Account or the sign-in screen: same cards, a Cancel instead of the pitch.
    case switchServer
    case cloud
    case selfHost
    case guide(ServerHostingOption)
    case connect(ServerHostingOption)
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The first pane. `.welcome` for a fresh install, `.switchServer` when changing servers.
    var start: OnboardingStep = .welcome
    /// Present when shown as a sheet: the root pane's Back becomes "Cancel".
    var onCancel: (() -> Void)?

    @State private var step: OnboardingStep?
    @State private var forward = true

    private var current: OnboardingStep { step ?? start }
    /// The pane Back returns to from the first level of either branch.
    private var root: OnboardingStep { start == .switchServer ? .switchServer : .welcome }

    private func go(_ next: OnboardingStep, advancing: Bool = true) {
        forward = advancing
        step = next
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if current == .welcome {
                embossBackdrop
                    .transition(reduceMotion ? .identity : backdropTurn)
            }
            ZStack {
                pane
                    .id(current)
                    .transition(reduceMotion ? .identity : pageTurn)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: current)
        // Someone choosing a server isn't describing the one the app points at now.
        .environment(\.handoffServerURL, "")
    }

    /// The page turn: the incoming pane drifts in from the direction of travel while the
    /// outgoing one drifts away — one orchestrated movement, ~0.25s, easing out.
    private var pageTurn: AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? 44 : -44).combined(with: .opacity),
            removal: .offset(x: forward ? -44 : 44).combined(with: .opacity)
        )
    }

    /// The letterpress backdrop belongs to the welcome pane only. The asset is greyscale+alpha
    /// with the relief baked into the ALPHA channel (fully transparent over flat paper, opaque
    /// in the impressions), so it is rendered as a masked tint, not a blend: the paper colour
    /// passes through EXACTLY where the sheet is flat, and the tint shows only in the relief.
    /// On the turn it moves in the same direction as the page but LESS (14pt to the page's 44)
    /// — that differential is what reads as depth. The 1.1 overscan keeps the drift from ever
    /// exposing an edge (14pt < the ~16pt minimum overscan at the narrowest window).
    ///
    /// Two falloff masks multiply the image alpha so the relief never crosses a glyph:
    /// `arcField` holds the impression around the arc signature, `copyFloor` dissolves it to
    /// nothing before the copy.
    private var embossBackdrop: some View {
        Rectangle()
            .fill(Palette.ink)
            .mask {
                Image("EmbossBackdrop")
                    .resizable()
                    .scaledToFill()
                    .mask { arcField }
                    .mask { copyFloor }
            }
            .scaleEffect(1.1)
            .ignoresSafeArea()
            .opacity(0.4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A radial held at full strength around the upper trailing area — where the asset's arc
    /// signature lives (centre of mass ~(0.80, 0.22)) — dissolving toward the lower leading
    /// corner. The radius scales with the window, so the hold survives Mac window resizing.
    private var arcField: some View {
        GeometryReader { geo in
            Rectangle().fill(
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.30),
                        .init(color: .clear, location: 1)
                    ],
                    center: UnitPoint(x: 0.80, y: 0.22),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.72
                )
            )
        }
    }

    /// Full strength through the open upper area, dissolving to NOTHING by 36% of the height —
    /// across the whole width — so no relief line can cross the wordmark, the value lines or the
    /// choice cards below it.
    private var copyFloor: some View {
        Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.22),
                    .init(color: .clear, location: 0.36)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var backdropTurn: AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? 14 : -14).combined(with: .opacity),
            removal: .offset(x: forward ? -14 : 14).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var pane: some View {
        switch current {
        case .welcome:
            WelcomePane(onCloud: { go(.cloud) }, onOwnServer: { go(.selfHost) })
        case .switchServer:
            SwitchServerPane(onCloud: { go(.cloud) }, onOwnServer: { go(.selfHost) },
                             onCancel: onCancel)
        case .cloud:
            CloudPane(onBack: { go(root, advancing: false) }, onDone: onCancel)
        case .selfHost:
            SelfHostPane(
                onPick: { option in go(option == .existing ? .connect(option) : .guide(option)) },
                onBack: { go(root, advancing: false) }
            )
        case .guide(let option):
            GuidePane(
                option: option,
                onConnect: { go(.connect(option)) },
                onBack: { go(.selfHost, advancing: false) }
            )
        case .connect(let option):
            ConnectPane(option: option, onBack: {
                go(option == .existing ? .selfHost : .guide(option), advancing: false)
            }, onDone: onCancel)
        }
    }
}

// MARK: - Welcome

private struct WelcomePane: View {
    var onCloud: () -> Void
    var onOwnServer: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        OnboardingPane(placement: .bottom) {
            OnboardingTopBar(handoff: .undecided)
        } content: {
            // `.bottom` settles the group just above the choices; the open upper area is where
            // the backdrop's rings live, clear of text. At accessibility sizes the choices join
            // the scrolling content — pinned, they would take most of the screen.
            VStack(spacing: 0) {
                group
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                if typeSize.isAccessibilitySize {
                    ServerChoiceCards(onCloud: onCloud, onOwnServer: onOwnServer)
                        .padding(.bottom, 8)
                }
            }
        } action: {
            if !typeSize.isAccessibilitySize {
                ServerChoiceCards(onCloud: onCloud, onOwnServer: onOwnServer)
            }
        }
    }

    /// Wordmark and value lines — one settled group, deliberately placed low.
    private var group: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandMark(size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text("Command")
                    .font(Typeface.display(40))
                    .foregroundStyle(Palette.ink)
                    // A wordmark must never break mid-word: at the largest Dynamic
                    // Type sizes it scales down to stay on one line instead.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Text("Plan it. Delegate it. Done.")
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ValueLine(title: "Capture fast", detail: "Type or speak a thought.")
                ValueLine(title: "The assistant shapes it", detail: "Notes become goals and tasks.")
                ValueLine(title: "Delegate with lead time", detail: "Each task reaches its person in time.")
            }
        }
    }
}

/// The two roads. Shared by the welcome and "Switch server" panes so there is one choice screen.
private struct ServerChoiceCards: View {
    var onCloud: () -> Void
    var onOwnServer: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Where should your notes live?")
                .font(Typeface.body(13, .semibold))
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ChoiceCard(systemImage: "cloud",
                       title: "Command Cloud",
                       detail: "Free. We run the server — just sign up.",
                       badge: "Recommended",
                       emphasized: true,
                       action: onCloud)
                .keyboardShortcut(.defaultAction)
            ChoiceCard(systemImage: "server.rack",
                       title: "My own server",
                       detail: "Railway, your computer, or an address you have.",
                       action: onOwnServer)
        }
        .padding(.top, 8)
    }
}

// MARK: - Switch server

private struct SwitchServerPane: View {
    @Environment(AppState.self) private var app
    var onCloud: () -> Void
    var onOwnServer: () -> Void
    var onCancel: (() -> Void)?

    var body: some View {
        OnboardingPane {
            PaneHeader(
                title: "Choose a server",
                lede: app.phase == .signedIn
                    ? "Switching signs you out here. Your data stays on the current server."
                    : "Pick where your account lives.",
                backTitle: "Cancel",
                onBack: onCancel,
                handoff: .undecided
            )
        } content: {
            ServerChoiceCards(onCloud: onCloud, onOwnServer: onOwnServer)
                .padding(.vertical, 16)
        } action: {
            EmptyView()
        }
    }
}

// MARK: - Command Cloud

private struct CloudPane: View {
    var onBack: () -> Void
    var onDone: (() -> Void)?

    @Environment(AppState.self) private var app
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        OnboardingPane {
            PaneHeader(title: "Command Cloud",
                       lede: "Hosted by Legitimate LLC, the makers of Command.",
                       onBack: onBack, handoff: .cloud)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                ValueLine(title: "Free",
                          detail: "Notes, calendar, tasks, people and goals — and Claude Code over MCP.")
                ValueLine(title: "The assistant is part of Command Pro",
                          detail: "Subscribe in the app whenever you want it. Everything else stays free.")
                ValueLine(title: "Your account, your data",
                          detail: "No other account can see it. Delete it from the app any time.")
                if let error {
                    ErrorBanner(message: error, retry: { Task { await connect() } })
                }
            }
            .padding(.vertical, 16)
        } action: {
            PrimaryButton(title: checking ? "Connecting…" : "Continue",
                          busy: checking, enabled: !checking) { Task { await connect() } }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
        }
    }

    private func connect() async {
        checking = true
        error = nil
        let result = await app.probeServer(ServerSetupGuide.cloudURL.absoluteString)
        if case .found(let url) = result {
            await app.chooseServer(url, hosting: nil)
            onDone?()
        } else {
            checking = false
            error = "Couldn't reach Command Cloud. Check your connection and try again."
        }
    }
}

// MARK: - My own server

private struct SelfHostPane: View {
    var onPick: (ServerHostingOption) -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingPane {
            PaneHeader(
                title: "Your own server",
                lede: "Everything stays on a machine you control. Pick what fits.",
                onBack: onBack,
                handoff: .undecided
            )
        } content: {
            VStack(spacing: 12) {
                ForEach(ServerHostingOption.allCases) { option in
                    ChoiceCard(systemImage: option.systemImage, title: option.title,
                               detail: option.subtitle, footnote: option.tradeoff) { onPick(option) }
                }
            }
            .padding(.vertical, 16)
        } action: {
            // The cards are this pane's action; the slot stays empty.
            EmptyView()
        }
    }
}

// MARK: - The guide (the signature pane)

/// Where a step sits in the reader's progress: `done` is crossed off in sage, `current` —
/// the first unticked step — carries the accent, and the rest wait in quiet ink.
private enum RailState: Equatable { case done, current, upcoming }

private struct GuidePane: View {
    let option: ServerHostingOption
    var onConnect: () -> Void
    var onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ticked: Set<Int> = []

    /// The accent belongs to the first step not yet ticked off.
    private var current: Int? { option.steps.first { !ticked.contains($0.index) }?.index }
    private var allDone: Bool { current == nil }

    var body: some View {
        OnboardingPane {
            PaneHeader(
                title: option.title,
                lede: "Tap each number as you finish it.",
                onBack: onBack,
                handoff: AgentHandoff.Path(option)
            )
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                steps
                Link(destination: ServerSetupGuide.helpURL) {
                    Label("Step-by-step help", systemImage: "arrow.up.right.square")
                        .font(Typeface.body(14, .semibold))
                }
                .tint(Palette.accent)
                .padding(.top, 20)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
        } action: {
            VStack(spacing: 8) {
                PrimaryButton(title: "Connect to my server", prominent: allDone, action: onConnect)
                    .keyboardShortcut(.defaultAction)
                if !allDone {
                    Text("Server already running? Connect now.")
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.top, 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: allDone)
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            ForEach(option.steps) { step in
                GuideStepRow(
                    step: step,
                    state: railState(for: step),
                    isLast: step.index == option.steps.count,
                    onToggle: { toggle(step.index) }
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ticked)
    }

    private func railState(for step: SetupStep) -> RailState {
        if ticked.contains(step.index) { return .done }
        return step.index == current ? .current : .upcoming
    }

    private func toggle(_ index: Int) {
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }
}

/// One instruction on the rail: the numeral in display type on the left, connected to the
/// next by a hairline rule, and the step's content on the right. Tapping the numeral ticks
/// the step off — crossed out in sage, the way you'd strike a line through a paper list.
private struct GuideStepRow: View {
    let step: SetupStep
    let state: RailState
    let isLast: Bool
    var onToggle: () -> Void

    private static let railWidth: CGFloat = 48

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onToggle) {
                Text("\(step.index)")
                    .font(Typeface.display(22))
                    .strikethrough(state == .done, color: Palette.sage)
                    .foregroundStyle(numeralColor)
                    .frame(minWidth: Self.railWidth, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Self.railWidth)
            .accessibilityLabel("Step \(step.index): \(step.title)")
            .accessibilityValue(state == .done ? "Done" : "Not done")
            .accessibilityHint(state == .done ? "Marks the step as not done" : "Ticks the step off")

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(Typeface.body(16, .semibold))
                    .foregroundStyle(state == .done ? Palette.inkSecondary : Palette.ink)
                Text(step.detail)
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = step.command {
                    CommandBlock(text: command).padding(.top, 4)
                }
                if let link = step.link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                            .font(Typeface.body(14, .semibold))
                    }
                    .tint(Palette.accent)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 11)   // optically level the title's first line with the numeral
        }
        .padding(.bottom, isLast ? 0 : 22)
        // The connecting rule. Drawn as a background (a bounded proposal) rather than a
        // greedy `.frame(maxHeight:)` inside the row, which would expand without limit in
        // the ScrollView. It runs from just below this numeral to the top of the next.
        .background(alignment: .topLeading) {
            if !isLast {
                Palette.hairline
                    .frame(width: 1)
                    .padding(.leading, (Self.railWidth - 1) / 2)
                    .padding(.top, 44)
                    .accessibilityHidden(true)
            }
        }
    }

    private var numeralColor: Color {
        switch state {
        case .done: return Palette.sage
        case .current: return Palette.accent
        case .upcoming: return Palette.inkSecondary
        }
    }
}

// MARK: - Connect

private struct ConnectPane: View {
    let option: ServerHostingOption
    var onBack: () -> Void
    var onDone: (() -> Void)?

    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var checking = false
    @State private var succeeded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var normalized: URL? { ServerSetupGuide.normalizedServerURL(text) }

    var body: some View {
        OnboardingPane {
            PaneHeader(
                title: "Connect",
                lede: "Paste your server's address. https:// is added if you leave it off.",
                onBack: onBack,
                handoff: AgentHandoff.Path(option)
            )
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FieldCard(icon: "link", isActive: focused) {
                    TextField("command.example.com", text: $text)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { Task { await connect() } }
                        .accessibilityLabel("Server address")
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                if let url = normalized,
                   ServerSetupGuide.isInsecure(url), !ServerSetupGuide.isLocalAddress(url) {
                    Label(
                        "That's an unencrypted http:// address on the public internet — fine on your own network, risky anywhere else.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.danger)
                }
                if let error {
                    ErrorBanner(message: error, retry: { Task { await connect() } })
                }
                if succeeded {
                    Label("Server found — connecting…", systemImage: "checkmark.circle.fill")
                        .font(Typeface.body(13, .semibold))
                        .foregroundStyle(Palette.sage)
                }

                Text("The first account on a new server becomes its owner. Invited by someone? Use the address from your invite.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)
        } action: {
            // Pinned in the container's action slot, the button rides up with the
            // keyboard (the pane respects the safe area; only the paper and backdrop
            // ignore it), and the ScrollView keeps the focused field revealed.
            PrimaryButton(
                title: checking ? "Checking…" : "Connect",
                busy: checking,
                enabled: normalized != nil && !checking
            ) { Task { await connect() } }
            .padding(.top, 12)
        }
        .onAppear {
            #if DEBUG
            // Screenshots/recordings: `-COMMAND_ONBOARDING_ADDRESS <text>` pre-fills the field
            // and leaves the keyboard down.
            if let preset = UserDefaults.standard.string(forKey: "COMMAND_ONBOARDING_ADDRESS") {
                text = preset
                return
            }
            #endif
            focused = true
        }
    }

    private func connect() async {
        guard normalized != nil else { return }
        focused = false
        checking = true
        error = nil
        // Confirm something is actually there before committing, so a typo surfaces here rather
        // than as a puzzling failure on the sign-in screen afterwards. On success the spinner
        // stays up until the app routes onward — that hand-off IS the success feedback; on
        // failure we come back with a banner the user can act on.
        let result = await app.probeServer(text)
        if case .found(let found) = result {
            succeeded = true
            await app.chooseServer(found, hosting: option)
            onDone?()
        } else {
            checking = false
            error = result.message
        }
    }
}
