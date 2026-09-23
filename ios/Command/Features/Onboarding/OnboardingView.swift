//
//  OnboardingView.swift
//  Command
//
//  The first thing a new person sees, and the only screen that has to justify itself.
//
//  Command has no default server: your notes, your plans and your assistant conversations live
//  on a machine you control. That is the product's whole point, and it is also a wall in front
//  of someone who just downloaded an app and expected a text field. So this flow does the
//  explaining — what the app is, why there is a setup step at all, the real hosting options
//  with their honest trade-offs, and the actual commands — instead of linking out to a docs
//  site the moment it gets hard.
//
//  It reads as a page from the planner itself: ink on paper, one accent, and — down the setup
//  steps — a numbered rail you tick off as you work, the way you'd check a list printed in
//  the margin. Panes turn like pages: a single short drift-and-fade in the direction of
//  travel, skipped entirely under Reduce Motion. Content and URL logic live in
//  `ServerSetupGuide`; this file only renders them.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private enum Step: Hashable { case intro, why, choose, guide(ServerHostingOption), connect }

    @State private var step: Step = .intro
    @State private var chosen: ServerHostingOption?
    @State private var forward = true

    private func go(_ next: Step, advancing: Bool = true) {
        forward = advancing
        step = next
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if step == .intro {
                embossBackdrop
                    .transition(reduceMotion ? .identity : backdropTurn)
            }
            ZStack {
                pane
                    .id(step)
                    .transition(reduceMotion ? .identity : pageTurn)
            }
            .frame(maxWidth: 560)
            .padding(28)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: step)
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
    /// The asset carries relief across its full height — its strongest band lands squarely on
    /// the value rows and read as strikethroughs — so "rings stay clear of text" is enforced
    /// here, structurally: two falloff masks multiply the image alpha. `arcField` holds the
    /// impression around the arc signature, `copyFloor` dissolves it to nothing before the copy.
    private var embossBackdrop: some View {
        Rectangle()
            .fill(embossTint)
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

    /// First falloff: a radial held at full strength around the upper trailing area — where the
    /// asset's arc signature actually lives (its centre of mass is ~(0.80, 0.22), not the empty
    /// corner) — dissolving toward the lower leading corner so the impression reads as pressed
    /// into the open paper rather than printed edge to edge. The radius scales with the window,
    /// so the hold survives Mac window resizing.
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

    /// Second falloff, and the one that keeps the copy clean: full strength through the open
    /// upper area, then dissolving to NOTHING by 47% of the height — across the whole width,
    /// so no relief line can cross a glyph in the value rows, their sub-lines or the card,
    /// however wide the widest line runs. (The wordmark sits just above the fade and keeps at
    /// most the faintest arc behind it.)
    private var copyFloor: some View {
        Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.34),
                    .init(color: .clear, location: 0.47)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The relief tint: pressed ink on the cream paper, caught light on the espresso one.
    /// `Palette.ink` is adaptive and is the right tone in both schemes — deep brown in light,
    /// the palette's light warm tone in dark — so both branches name it; the explicit pick
    /// keeps the two schemes independently tunable.
    private var embossTint: Color {
        colorScheme == .dark ? Palette.ink : Palette.ink
    }

    private var backdropTurn: AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? 14 : -14).combined(with: .opacity),
            removal: .offset(x: forward ? -14 : 14).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var pane: some View {
        switch step {
        case .intro:
            WelcomePane { go(.why) }
        case .why:
            WhyPane(
                onContinue: { go(.choose) },
                onBack: { go(.intro, advancing: false) }
            )
        case .choose:
            ChoosePane(
                onPick: { option in
                    chosen = option
                    go(option == .existing ? .connect : .guide(option))
                },
                onBack: { go(.why, advancing: false) }
            )
        case .guide(let option):
            GuidePane(
                option: option,
                onConnect: { go(.connect) },
                onBack: { go(.choose, advancing: false) }
            )
        case .connect:
            ConnectPane(onBack: {
                go(chosen.map { $0 == .existing ? .choose : .guide($0) } ?? .choose,
                   advancing: false)
            })
        }
    }
}

// MARK: - Shared pieces

/// The one action style across the flow: a full-width button that is either the accent-filled
/// primary or its quiet surface-bound twin. Prominence is a state, never a gate — a muted
/// button still works (someone whose server is already running must be able to skip ahead).
private struct PrimaryButton: View {
    let title: String
    var prominent = true
    var busy = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(title).font(Typeface.body(16, .semibold))
            }
            .foregroundStyle(prominent ? .white : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)   // min, not fixed — grows with Dynamic Type instead of clipping
            .padding(.vertical, 4)
            .background(prominent ? Palette.accent : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                }
            }
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct BackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(Typeface.body(15, .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.inkSecondary)
        .padding(.bottom, 4)
    }
}

/// A short value statement: semibold claim, one quiet line of detail. Typographic only —
/// the rail and the tick-off are this flow's decoration; everything else stays quiet.
private struct ValueLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typeface.body(15, .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A copyable command. Copying matters more than it looks — the alternative is retyping a
/// `docker compose` line from a phone screen onto a laptop.
private struct CommandBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                // A command with no natural break point (a bare URL) truncates with an
                // ellipsis inside the HStack instead of wrapping — the user can't read what
                // they're about to copy. Claim the height the wrap needs.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Palette.sage : Palette.inkSecondary)
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline)
        )
    }
}

// MARK: - The pane container

/// The one vertical rhythm of the whole flow: header anchored top, action anchored
/// bottom, and the pane's substance centred in the space left between. Leftover space
/// splits above and below the content instead of lumping at the bottom, so a sparse
/// pane reads as composed rather than unfinished. A dense pane (the guide) fills the
/// space and is unchanged; an over-tall one (short screens, accessibility2 type)
/// scrolls rather than clipping. Every pane is built from this container — they
/// differ only in what they put in the three slots.
private struct OnboardingPane<Header: View, Content: View, Action: View>: View {
    /// Where content rests in leftover space. `.center` splits it above and below.
    /// `.bottom` settles the content low, leaving the space open above — the welcome
    /// pane's deliberate window for the backdrop's rings.
    enum ContentPlacement { case center, bottom }

    let placement: ContentPlacement
    let header: Header
    let content: Content
    let action: Action

    init(placement: ContentPlacement = .center,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content,
         @ViewBuilder action: () -> Action) {
        self.placement = placement
        self.header = header()
        self.content = content()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GeometryReader { geo in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, minHeight: geo.size.height,
                               alignment: placement == .center ? .center : .bottom)
                }
            }
            action
        }
    }
}

/// The anchored top of a pane: back button, title, and (where given) the one-line lede.
private struct PaneHeader: View {
    let title: String
    var lede: String? = nil
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackButton(action: onBack)
            Text(title)
                .font(Typeface.display(26))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            if let lede {
                Text(lede)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomePane: View {
    var onContinue: () -> Void

    var body: some View {
        OnboardingPane(placement: .bottom) {
            EmptyView()
        } content: {
            // `.bottom` + these fixed insets reproduce this pane's verified geometry
            // exactly through the shared container: the group settles just above the
            // button, and the open upper area — where the backdrop's rings live —
            // stays clear of text.
            group
                .padding(.top, 40)
                .padding(.bottom, 28)
        } action: {
            PrimaryButton(title: "Get started", action: onContinue)
                .keyboardShortcut(.defaultAction)   // ⏎ on Mac / hardware keyboard
                .padding(.top, 12)
        }
    }

    /// Wordmark, value lines and the honest card — one settled group, deliberately
    /// placed low rather than centred; the space above it is the ring window.
    private var group: some View {
        VStack(alignment: .leading, spacing: 22) {
            brandMark
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
            VStack(alignment: .leading, spacing: 16) {
                ValueLine(title: "Capture fast",
                          detail: "Type or speak a thought.")
                ValueLine(title: "The assistant shapes it",
                          detail: "Notes become goals and tasks.")
                ValueLine(title: "Delegate with lead time",
                          detail: "Each task reaches its person in time to get done.")
            }

            // The one honest line, set apart so it isn't skimmed past: the next
            // thing this app asks for is a server, and that is a feature, not an error.
            Text("Your notes live on a server you own — we don't have one.")
                .font(Typeface.body(14, .medium))
                .foregroundStyle(Palette.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: 14, elevated: false)
        }
    }

    /// The same wordmark treatment as the sign-in screen, so the first-run flow and the
    /// auth flow read as one product.
    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.accentSoft)
                .frame(width: 80, height: 80)
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Why your own server

private struct WhyPane: View {
    var onContinue: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingPane {
            PaneHeader(title: "Why your own server", onBack: onBack)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Everything you capture — notes, plans and every conversation with your assistant — lives on a machine you control. There is no Command cloud: the app has nowhere else to send your data, and we never see a word of it.")
                    .font(Typeface.body(16))
                    .foregroundStyle(Palette.ink)
                Text("Setting yours up takes a few minutes, and the next screens walk you through it.")
                    .font(Typeface.body(16))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)
        } action: {
            PrimaryButton(title: "Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
        }
    }
}

// MARK: - Choose a host

private struct ChoosePane: View {
    var onPick: (ServerHostingOption) -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingPane {
            PaneHeader(
                title: "Choose hosting",
                lede: "Your server holds everything you capture. Pick what fits — you can move later by pointing the app at a new address.",
                onBack: onBack
            )
        } content: {
            VStack(spacing: 12) {
                ForEach(ServerHostingOption.allCases) { option in
                    OptionCard(option: option) { onPick(option) }
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
        } action: {
            // The cards are this pane's action; the slot stays empty.
            EmptyView()
        }
    }
}

private struct OptionCard: View {
    let option: ServerHostingOption
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(Typeface.body(16, .semibold)).foregroundStyle(Palette.ink)
                    Text(option.subtitle)
                        .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                    if let tradeoff = option.tradeoff {
                        // The trade-off rides on the card so it is read before the choice,
                        // not discovered after it.
                        Text(tradeoff)
                            .font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
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
                lede: "Work through these one by one, tapping each number as you finish it.",
                onBack: onBack
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
                    Text("Server already running? You can connect without finishing the list.")
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
    var onBack: () -> Void

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
                onBack: onBack
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

                Text("The first account created on a new server becomes its owner, and signup closes behind it. Invited by someone? Use the server address from your invite.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkSecondary)
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
        .onAppear { focused = true }
    }

    private func connect() async {
        guard normalized != nil else { return }
        focused = false
        checking = true
        error = nil
        // Confirm something is actually there before committing, so a typo surfaces here rather
        // than as a puzzling failure on the sign-in screen afterwards. On success the spinner
        // stays up until `setServerURL` routes the app onward — that hand-off IS the success
        // feedback; on failure we come back with a banner the user can act on.
        let result = await app.probeServer(text)
        if case .found(let found) = result {
            succeeded = true
            await app.setServerURL(found.absoluteString)
        } else {
            checking = false
            error = result.message
        }
    }
}
