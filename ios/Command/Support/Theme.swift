//
//  Theme.swift
//  Command
//
//  The design system: a warm "paper-and-ink" planner. Deep ink on warm paper,
//  a single confident burnt-amber accent, and the system serif (New York) for
//  display type so the app reads like a beautiful notebook rather than generic
//  SF-everywhere. One source of truth for color, type, and the few shared shapes.
//

import SwiftUI
import UIKit

extension Color {
    /// Light/dark adaptive color from two sRGB triples.
    init(lightHex l: (Double, Double, Double), darkHex d: (Double, Double, Double)) {
        self = Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum Palette {
    /// App background — warm paper / deep espresso.
    static let paper = Color(lightHex: (0.965, 0.949, 0.918), darkHex: (0.102, 0.090, 0.078))
    /// Raised surfaces (cards, the capture bar, rows).
    static let surface = Color(lightHex: (0.988, 0.980, 0.965), darkHex: (0.149, 0.125, 0.098))
    /// Primary text.
    static let ink = Color(lightHex: (0.129, 0.110, 0.086), darkHex: (0.925, 0.890, 0.839))
    /// Secondary text, captions, metadata.
    static let inkSecondary = Color(lightHex: (0.420, 0.384, 0.325), darkHex: (0.663, 0.620, 0.549))
    /// The one accent — burnt amber.
    static let accent = Color(lightHex: (0.706, 0.345, 0.086), darkHex: (0.878, 0.518, 0.227))
    /// Accent wash for soft fills / selection.
    static let accentSoft = Color(lightHex: (0.706, 0.345, 0.086), darkHex: (0.878, 0.518, 0.227)).opacity(0.12)
    /// Calm secondary — muted sage (done / scheduled states).
    static let sage = Color(lightHex: (0.360, 0.450, 0.330), darkHex: (0.560, 0.660, 0.525))
    /// Hairline separators.
    static let hairline = Color(lightHex: (0.0, 0.0, 0.0), darkHex: (1.0, 1.0, 1.0)).opacity(0.09)
    /// Overdue / warning — a warm brick red that reads clearly against paper without clashing
    /// with the terracotta accent.
    static let danger = Color(lightHex: (0.784, 0.243, 0.196), darkHex: (0.906, 0.400, 0.361))
}

enum Typeface {
    /// Editorial display (titles, brand). System serif = New York, and — unlike a bare
    /// `.system(size:)`, which is a FIXED size that ignores the user's Larger Text setting —
    /// scaled through `UIFontMetrics` so display text grows with Dynamic Type. Scaling is
    /// bounded by the app-wide `.dynamicTypeSize` clamp (see RootView) so huge accessibility
    /// sizes stay readable without shattering fixed layouts.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        let serif = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        return Font(UIFontMetrics(forTextStyle: .body).scaledFont(for: serif))
    }

    /// Primary sans content text (row titles, chat, detail body), scaled with Dynamic Type
    /// the same way. Use for text the user actually reads; leave tiny fixed chrome (badges,
    /// calendar day digits, dots) on `.system(size:)` so it can't clip its frame.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: size, weight: uiWeight(weight))
        ))
    }

    private static func uiWeight(_ w: Font.Weight) -> UIFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}

/// A soft, warm card surface used throughout (capture bar, rows, sheets).
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var elevated: Bool = true
    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevated ? 0.10 : 0), radius: elevated ? 14 : 0, x: 0, y: elevated ? 6 : 0)
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 18, elevated: Bool = true) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, elevated: elevated))
    }

    /// Re-skin a native `Form`/`List` to the app: warm paper behind the grouped
    /// rows + amber controls. Keeps Form's native behaviors (sections, footers,
    /// keyboard handling, the macOS settings look) while staying on-brand — vs
    /// the default system-gray grouped background, which looks generic against
    /// the notebook palette.
    func brandedForm() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.paper.ignoresSafeArea())
            .tint(Palette.accent)
    }

    /// A custom display-only row/card that navigates on tap. Wires the pointer/touch
    /// tap AND exposes the row to VoiceOver as ONE activatable button element. Use in
    /// place of a bare `.onTapGesture`, which gives no accessibility affordance — a
    /// plain tap gesture isn't announced as a control, so VoiceOver users can't tell
    /// the row opens anything or activate it. Do NOT use on a row that contains its
    /// own focusable controls (a toggle, an inline menu): combining the children would
    /// swallow them. Use `rowOpenAction` there instead. (A trailing `.contextMenu` is
    /// fine — its actions stay reachable via the VoiceOver Actions rotor.)
    func tappableRow(perform action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    /// Like `tappableRow`, but for a row that contains its own focusable controls
    /// (e.g. a done-toggle and a menu). Keeps those children individually accessible
    /// and adds the row's "open" as the VoiceOver default action (reachable via the
    /// Actions rotor) rather than collapsing the whole row into a single button.
    func rowOpenAction(perform action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAction(.default) { action() }
    }
}

// MARK: - Relative time

enum RelativeTime {
    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    private static let style = RelativeDateTimeFormatter()

    /// "2h ago" style for an ISO-8601 timestamp; falls back to the raw string.
    static func ago(_ iso: String) -> String {
        guard let date = parser.date(from: iso) ?? plain.date(from: iso) else { return iso }
        // Server clock skew can put a just-written timestamp seconds in the future,
        // which the formatter renders as "in 0 seconds". Every caller means "ago".
        if date.timeIntervalSinceNow > -60 { return String(localized: "just now") }
        return style.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Error banner

/// A reusable, on-brand error banner with an optional retry action. Use it anywhere a
/// store exposes an `errorMessage` so failures don't masquerade as empty states.
struct ErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
                    .font(Typeface.body(13, .semibold))
                    .tint(Palette.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.danger.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}
